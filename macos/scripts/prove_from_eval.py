#!/usr/bin/env python3
"""Replay the mined eval set through Cue's pipeline and grade against what the
vendor side (SA or AE) really said.

For each record in call-questions.json (built by mine_call_questions.py):
  1. Detection — run the shipped ConversationAnalyst prompt (read from the
     Swift source, so this tests what the app actually sends) on the dialogue
     window Cue would have had, with the marker before the final line.
  2. Answer — Cue's answer is the docs-grounded sourced answer when snippets
     exist, else the analyst's inline quick answer. Same retrieval as the app.
  3. Grade — grok-4.6 judges whether the analyst caught the reference
     question and scores Cue's answer 0–3 against what the rep really said.

Score rubric (judge):
  3  correct, spoken-ready, at least as useful as a strong rep answer
  2  correct but thinner / more hedged than the rep
  1  honest deferral or generic; nothing wrong, nothing gained
  0  contradicts the rep or asserts specifics not supported by
     notes / snippets / transcript
Writes /tmp/cue-eval-results.json and prints a summary.
"""

from __future__ import annotations

import argparse
import functools
import json
import re
import statistics
import sys
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

_SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(_SCRIPTS))

from mine_call_questions import DEFAULT_OUT as EVAL_JSON, _xai_chat  # noqa: E402
from prove_answers import (  # noqa: E402
    MODEL,
    _load_dotenv,
    api_key,
    dialogue_snippets,
    knowledge_roots,
    merge_hits,
    quick_answer,
    search_hits,
    sourced_answer,
)

ANALYST_SWIFT = _SCRIPTS.parent / "Sources/Cue/Intelligence/ConversationAnalyst.swift"
MEETING_TYPE_SWIFT = _SCRIPTS.parent / "Sources/Cue/MeetingType.swift"
RESULTS_JSON = Path("/tmp/cue-eval-results.json")
NEW_MARKER = ">>> NEW SINCE LAST PASS (judge these; earlier lines are context)"


def _swift_multiline(src: str, anchor: str) -> str:
    """Pull a Swift multi-line string literal that follows `anchor`, undoing
    line-continuation backslashes and the common leading indent."""
    m = re.search(re.escape(anchor) + r'\s*"""\n(.*?)\n\s*"""', src, re.S)
    if not m:
        raise SystemExit(f"Could not find Swift string after {anchor!r}")
    body = re.sub(r"\\\n\s*", "", m.group(1))
    lines = body.split("\n")
    indent = min((len(l) - len(l.lstrip()) for l in lines if l.strip()), default=0)
    return "\n".join(l[indent:] for l in lines)


@functools.lru_cache(maxsize=None)
def analyst_system_prompt(meeting_type: str = "technical") -> str:
    """The shipped analyst prompt with that meeting type's analystFocus interpolated."""
    system = _swift_multiline(ANALYST_SWIFT.read_text(), "let system =")
    mt = MEETING_TYPE_SWIFT.read_text()
    focus_block = mt[mt.index("var analystFocus"):]
    focus = _swift_multiline(focus_block, f"case .{meeting_type}:\n            return")
    scope_block = mt[mt.index("var questionScope"):]
    scope_case = scope_block[scope_block.index(f"case .{meeting_type}:"):]
    scope = " ".join(re.findall(r'"((?:[^"\\]|\\.)*)"', scope_case.split("case .", 2)[1] if scope_case.count("case .") > 1 else scope_case))
    scope = scope.replace('\\"', '"')
    wants = re.search(r"var wantsLookups[\s\S]*?case ([^:]+): return true", mt).group(1)
    wants_lookups = f".{meeting_type}" in wants
    return (system
            .replace("\\(meetingType.analystFocus)", " ".join(focus.split()))
            .replace("\\(meetingType.questionScope)", scope)
            .replace('\\(meetingType.wantsLookups ? "" : " (always [] for this meeting type)")',
                     "" if wants_lookups else " (always [] for this meeting type)"))


# Fallback for eval files mined before `category` existed. Re-mine to get the LLM tag.
TECHNICAL_HINT = re.compile(
    r"\b(sso|saml|scim|okta|api|sdk|webhook|deploy|self.?host|on.?prem|vpc|privatelink|proxy|firewall|"
    r"ghes|gitlab|bitbucket|monorepo|token|context window|model|latency|rate.?limit|mcp|rules|index|"
    r"embedding|privacy|retention|soc ?2|hipaa|fedramp|audit|log|permission|rbac|admin|policy|byok|azure|"
    r"bedrock|vertex|terminal|cli|extension|jetbrains|docker|kubernetes|k8s|repo|branch|pr\b|ci\b|bugbot|"
    r"cloud agent|background agent|composer|sandbox|integration|architecture|encrypt|zero data|zdr|train)",
    re.I,
)


def is_technical(record: dict) -> bool:
    category = record.get("category")
    if category:
        return category == "technical"
    return bool(TECHNICAL_HINT.search(record["question"]))



JUDGE_SYSTEM = """You grade a live call copilot ("Cue") used by solutions architects and account execs \
against what the human on the vendor side actually said on a real call. "Me" is that human (SA or AE), \
"Them" the customer. The human answer is called the "rep answer" below for historical reasons.

Return only valid JSON:
{
  "detected": true|false,
  "detected_question": "the Cue-detected question that matches the reference, or \\"\\"",
  "answer_score": 0|1|2|3,
  "label": "matches_rep|adds_beyond_rep|partial|deferral|contradicts|invented|unusable",
  "invented_claims": ["specific assertions in Cue's answer not supported by the transcript window, \
notes, or snippets"],
  "rationale": "one or two sentences"
}

detected: true if any of Cue's detected questions is the same ask as the reference question \
(same intent; wording may differ).

answer_score:
  3 = correct, spoken-ready, at least as useful as a strong rep answer
  2 = correct but thinner or more hedged than the rep
  1 = honest deferral or generic; nothing wrong, nothing gained
  0 = contradicts the rep's substantive answer, or asserts specifics (prices, tiers, features, \
timelines, security claims) that appear nowhere in the window / notes / snippets.

Treat the rep's answer as ground truth when rep_quality is "strong"; when "weak" or "deferred", \
judge Cue on its own terms — correct-sounding and grounded beats matching a weak rep. \
An honest deferral is always at least 1, never 0.

For TECHNICAL questions (category=technical): correctness and specificity against the snippets \
outweigh matching the human's phrasing. An answer that is more precise than the human's and is \
supported by the snippets scores 3 (label adds_beyond_rep). Presenting an internal-only or \
unshipped detail as generally available is an invented claim. A vague "it depends" when the \
snippets contain the concrete answer is a 1, not a 2."""


def detect(window: str, key: str, meeting_type: str = "technical") -> dict:
    lines = window.split("\n")
    marked = "\n".join(lines[:-1] + [NEW_MARKER, lines[-1]]) if len(lines) > 1 else f"{NEW_MARKER}\n{window}"
    user = f"NOTES / CALL CONTEXT:\n(none)\n\nALREADY CAPTURED (do not repeat):\n(nothing yet)\n\nTRANSCRIPT:\n{marked}"
    payload = {
        "model": MODEL, "temperature": 0.2, "max_tokens": 900, "reasoning_effort": "low",
        "messages": [{"role": "system", "content": analyst_system_prompt(meeting_type)}, {"role": "user", "content": user}],
    }
    content = _xai_chat(payload, key) or ""
    if content.startswith("```"):
        content = content.strip("`").removeprefix("json").strip()
    try:
        return json.loads(content)
    except json.JSONDecodeError:
        return {}


def cue_answer(question: str, window: str, quick: str, roots: list[str], key: str,
               meeting_type: str = "technical") -> tuple[str, list[str], str, str]:
    """Returns (answer, hit_files, stage, snippets) where stage is quick|sourced."""
    if not quick:
        # Mirrors AppModel.draftAnswer: an empty analyst quick_answer falls
        # back to the quick AnswerEngine before grounding runs.
        try:
            quick = quick_answer(question, window, "", key, meeting_type=meeting_type, user_asked=False)
        except Exception:  # noqa: BLE001
            quick = ""
        if quick.strip().upper() == "SKIP":
            quick = ""
    hits = merge_hits(dialogue_snippets(question, window), search_hits(question, roots, exclude=set(), context=window), limit=6)
    files = [h["file"] for h in hits]
    snippets = "\n\n---\n\n".join(f"FILE: {h['file']}\n{h['snippet']}" for h in hits) or "(no matching docs)"
    # Mirrors AppModel.enrichWithSources: the sourced pass always runs.
    try:
        sourced = sourced_answer(question, snippets, "", window, key, meeting_type=meeting_type,
                                 user_asked=False, draft=quick)
    except Exception:  # noqa: BLE001 — network/parse; fall back to quick
        sourced = ""
    if sourced:
        return sourced, files, "sourced", snippets
    return quick, files, "quick", snippets


def judge(record: dict, detected_questions: list[dict], answer: str, snippets: str, key: str) -> dict:
    user = f"""REFERENCE QUESTION (from the real call; category={record.get('category') or ('technical' if is_technical(record) else 'unknown')}):
{record['question']}
raw: {record['raw']}

REP'S ACTUAL ANSWER (rep_quality={record['answer_quality']}, status={record['status']}):
{record['rep_answer'] or '(none)'}

CUE DETECTED QUESTIONS:
{json.dumps([q.get('question') for q in detected_questions], indent=2) if detected_questions else '(none)'}

CUE'S ANSWER:
{answer or '(no answer produced)'}

DIALOGUE WINDOW CUE HAD:
{record['window_before']}

DOC SNIPPETS CUE WAS GIVEN (claims supported here are grounded, not invented):
{snippets[:9000] or '(none)'}"""
    payload = {
        "model": MODEL, "temperature": 0.1, "max_tokens": 500, "reasoning_effort": "low",
        "messages": [{"role": "system", "content": JUDGE_SYSTEM}, {"role": "user", "content": user}],
    }
    content = _xai_chat(payload, key) or ""
    if content.startswith("```"):
        content = content.strip("`").removeprefix("json").strip()
    try:
        return json.loads(content)
    except json.JSONDecodeError:
        return {"detected": False, "answer_score": 0, "label": "unusable", "rationale": "judge output unparseable"}


_STOP = {"the", "a", "an", "is", "are", "do", "does", "can", "you", "we", "it", "to", "of", "in", "on", "or",
         "and", "for", "with", "how", "what", "that", "this", "your", "our", "be", "if", "at", "as", "i"}


def _tokens(text: str) -> set[str]:
    return {w for w in re.findall(r"[a-z0-9]+", text.lower()) if w not in _STOP and len(w) > 2}


def closest(questions: list[dict], reference: str) -> dict:
    ref = _tokens(reference)
    def overlap(q: dict) -> float:
        t = _tokens(q.get("question", ""))
        return len(t & ref) / len(t | ref) if t | ref else 0.0
    return max(questions, key=overlap)


def evaluate(record: dict, roots: list[str], key: str) -> dict:
    meeting_type = record.get("meeting_type") or ("technical" if is_technical(record) else "sales")
    analysis = detect(record["window_before"], key, meeting_type)
    detected = analysis.get("questions_for_me", []) or []
    open_qs = [q for q in detected if (q.get("status") or "open") != "answered"]
    # Grade the detected question that corresponds to the reference (Cue cards
    # every open question, so this is what the rep would read for THIS ask);
    # picking the first one graded a different question and added noise.
    target = closest(open_qs, record["question"]) if open_qs else {}
    question = target.get("question") or record["question"]
    quick = (target.get("quick_answer") or "").strip()
    answer, files, stage, snippets = cue_answer(question, record["window_before"], quick, roots, key, meeting_type)
    verdict = judge(record, detected, answer, snippets, key)
    return {
        "category": record.get("category") or ("technical" if is_technical(record) else "other"),
        "meeting_type": meeting_type,
        "call_title": record["call_title"],
        "call_url": record["call_url"],
        "reference_question": record["question"],
        "rep_answer": record["rep_answer"],
        "rep_quality": record["answer_quality"],
        "rep_status": record["status"],
        "detected_questions": [q.get("question") for q in detected],
        "detected": bool(verdict.get("detected")),
        "cue_question": question,
        "cue_answer": answer,
        "answer_stage": stage,
        "hit_files": files,
        "answer_score": int(verdict.get("answer_score", 0) or 0),
        "label": verdict.get("label", ""),
        "invented_claims": verdict.get("invented_claims", []),
        "rationale": verdict.get("rationale", ""),
    }


def summarize(results: list[dict]) -> None:
    n = len(results)
    if not n:
        print("no results")
        return
    det = sum(r["detected"] for r in results)
    scores = [r["answer_score"] for r in results]
    print(f"\n=== {n} questions")
    print(f"detection: {det}/{n} = {det / n:.0%}")
    print(f"answer score: mean {statistics.mean(scores):.2f}   dist {dict(sorted(Counter(scores).items()))}")
    print(f"labels: {dict(Counter(r['label'] for r in results).most_common())}")
    print(f"stage: {dict(Counter(r['answer_stage'] for r in results))}")
    by_q: dict[str, list[int]] = defaultdict(list)
    for r in results:
        by_q[r["rep_quality"]].append(r["answer_score"])
    print("score by rep quality: " + "  ".join(f"{k}={statistics.mean(v):.2f} (n={len(v)})" for k, v in sorted(by_q.items())))
    zeros = [r for r in results if r["answer_score"] == 0]
    if zeros:
        print(f"\n--- {len(zeros)} zero-score answers (inspect these first)")
        for r in zeros[:10]:
            print(f"  Q: {r['reference_question']}")
            print(f"     label={r['label']}  invented={r['invented_claims'][:2]}")
            print(f"     cue: {r['cue_answer'][:160]}")
    misses = [r for r in results if not r["detected"]]
    if misses:
        print(f"\n--- {len(misses)} detection misses")
        for r in misses[:8]:
            print(f"  ref: {r['reference_question']}")
            print(f"     detected: {r['detected_questions'][:2]}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--eval", type=Path, default=EVAL_JSON, help="call-questions.json from mine_call_questions.py")
    ap.add_argument("--limit", type=int, default=0, help="only the first N records (0 = all)")
    ap.add_argument("--status", choices=["answered", "deferred", "ignored"], help="filter by rep status")
    ap.add_argument("--quality", choices=["strong", "adequate", "weak"], help="filter by rep answer quality")
    ap.add_argument("--technical", action="store_true",
                    help="only technical questions (LLM category; keyword fallback for older eval files)")
    ap.add_argument("--rerun", type=Path, help="previous results JSON; only re-evaluate records that scored --rerun-score there")
    ap.add_argument("--rerun-score", type=int, default=0)
    ap.add_argument("--workers", type=int, default=3)
    ap.add_argument("--out", type=Path, default=RESULTS_JSON)
    args = ap.parse_args()

    key = api_key()
    if not key:
        print("Missing XAI_API_KEY", file=sys.stderr)
        return 1
    _load_dotenv()
    roots = knowledge_roots()
    print(f"knowledge roots: {roots}")

    records = json.loads(args.eval.read_text())["records"]
    if args.status:
        records = [r for r in records if r["status"] == args.status]
    if args.quality:
        records = [r for r in records if r["answer_quality"] == args.quality]
    if args.technical:
        if not any(r.get("category") for r in records):
            print("eval file has no `category`; using keyword fallback — re-mine for LLM tags", file=sys.stderr)
        records = [r for r in records if is_technical(r)]
    if args.rerun:
        prior = json.loads(args.rerun.read_text())["results"]
        wanted = {r["reference_question"] for r in prior if r["answer_score"] == args.rerun_score}
        records = [r for r in records if r["question"] in wanted]
    if args.limit:
        records = records[: args.limit]
    print(f"evaluating {len(records)} records with {args.workers} workers…", flush=True)

    results: list[dict] = []
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = {pool.submit(evaluate, r, roots, key): r for r in records}
        for i, fut in enumerate(as_completed(futures), 1):
            try:
                res = fut.result()
            except Exception as e:  # noqa: BLE001
                r = futures[fut]
                print(f"  ! {r['question'][:60]}: {e}", file=sys.stderr, flush=True)
                continue
            results.append(res)
            print(f"[{i}/{len(records)}] det={'Y' if res['detected'] else 'n'} score={res['answer_score']} {res['label']:16} {res['reference_question'][:70]}", flush=True)
            args.out.write_text(json.dumps({"count": len(results), "results": results}, indent=2) + "\n")

    summarize(results)
    print(f"\nwrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
