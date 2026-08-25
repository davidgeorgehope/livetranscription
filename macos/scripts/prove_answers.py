#!/usr/bin/env python3
"""Headless Cue answer-proof harness (Design A).

Run:
  python3 macos/scripts/prove_answers.py [--session call-....md] [--limit 8] \\
      [--min-answered 3] [--notes ""] [--meeting-type sales|interview|internal] \\
      [--ask "…"]

Exit 0 when at least --min-answered probes have non-empty quick or sourced text.
With --ask, runs a single user-ask probe (no SKIP-as-non-customer) and requires
a non-empty answer (min_answered defaults to 1).
Exit 1 on shortfall / missing API key / no probes. Writes /tmp/cue-prove-answers.json.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

_SCRIPTS = Path(__file__).resolve().parent
if str(_SCRIPTS) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS))

from repro_source_search import MAX_DF, keywords, path_boost, rg  # noqa: E402

SESSIONS_DIR = Path.home() / "Library/Application Support/Cue/sessions"
OUT_JSON = Path("/tmp/cue-prove-answers.json")
MODEL = "grok-4.6"
API_URL = "https://api.x.ai/v1/chat/completions"
LINE_RE = re.compile(r"^- \*\*(.+?)\*\* \(([^)]+)\):\s*(.*)$")
WINDOW_WORDS = 280

MEETING_ALIASES = {
    "sales": "sales",
    "interview": "interview",
    "internal": "internalSync",
    "internalsync": "internalSync",
}

# Mirror QuestionDetector.swift verbs.
QUESTION_VERBS = (
    "can you", "could you", "would you", "will you", "do you", "does it",
    "did you", "how do", "how does", "how would", "how can", "what is",
    "what's", "what are", "what does", "what do", "why is", "why does",
    "when will", "when can", "where is", "is there", "are you", "are there",
    "should we", "should i", "pricing", "how much", "how long", "how many",
)

# Drop pure call-facilitation so the harness proves product answers, not
# "can you share your screen?"
SKIP_QUESTION_SUBSTR = (
    "share your screen",
    "share my screen",
    "can you hear",
    "can everyone hear",
    "mute yourself",
    "you're on mute",
)


def quick_system(meeting_type: str, user_asked: bool) -> str:
    if meeting_type == "interview":
        if user_asked:
            return (
                "You are a live interviewer copilot. The interviewer typed a request for help "
                "during a hiring interview. Help them evaluate the candidate, suggest follow-ups, "
                "or summarize signal — for the interviewer, not as something to say to a customer.\n\n"
                "Rules:\n"
                "- 2 to 5 short sentences or bullets. No preamble.\n"
                "- Prefer evidence from RECENT TRANSCRIPT and NOTES.\n"
                "- If suggesting a question to ask the candidate, label it clearly as a candidate question.\n"
                "- Do not invent candidate claims absent from the transcript.\n"
                "- Always answer. Never reply SKIP.\n"
            )
        return (
            "You are a live interviewer copilot. Something in the conversation may need a brief "
            "note for the interviewer.\n\n"
            "Rules:\n"
            "- 2 to 4 short sentences for the interviewer (eval signal, follow-up, or red flag).\n"
            "- Prefer evidence from NOTES and RECENT TRANSCRIPT.\n"
            "- Do not invent candidate claims.\n"
            "- Only reply SKIP if there is nothing useful for the interviewer.\n"
        )
    if meeting_type == "internalSync":
        if user_asked:
            return (
                "You are a terse meeting aide for an internal sync. The user asked for help.\n\n"
                "Rules:\n"
                "- 1 to 4 short sentences. Prefer decisions, owners, clarify-asks, and risks.\n"
                "- Prefer facts from NOTES and RECENT TRANSCRIPT.\n"
                "- Do not invent commitments or owners.\n"
                "- Always answer. Never reply SKIP.\n"
            )
        return (
            "You are a terse meeting aide for an internal sync.\n\n"
            "Rules:\n"
            "- 1 to 3 short sentences on decisions, owners, or clarify-asks.\n"
            "- Prefer facts from NOTES and RECENT TRANSCRIPT.\n"
            "- Only reply SKIP if there is nothing actionable.\n"
        )
    if user_asked:
        return (
            "You are a live sales/customer-call copilot sitting next to the user.\n"
            "The user typed a question for help. Give a spoken-ready answer they can use in the next 5 seconds.\n\n"
            "Rules:\n"
            "- 2 to 4 short sentences. No preamble.\n"
            "- Prefer facts from NOTES, then from what was already said in the RECENT TRANSCRIPT "
            "(setup steps, decisions, names, what the user already committed to on this call).\n"
            "- Do not invent prices, SLAs, legal commitments, or product claims that are not in notes/transcript.\n"
            "- For process/UI/setup questions, a clear next step from the conversation is useful — give it.\n"
            "- Always answer. Never reply SKIP.\n"
            "- If you truly lack the fact, give a short spoken deferral the user can say.\n"
        )
    return (
        "You are a live sales/customer-call copilot sitting next to the user.\n"
        "A customer just asked a question. Give the user a spoken-ready answer they can say in the next 5 seconds.\n\n"
        "Rules:\n"
        "- 2 to 4 short sentences. No preamble.\n"
        "- Prefer facts from NOTES, then from what was already said in the RECENT TRANSCRIPT "
        "(setup steps, decisions, names, what the user already committed to on this call).\n"
        "- Do not invent prices, SLAs, legal commitments, or product claims that are not in notes/transcript.\n"
        "- For process/UI/setup questions, a clear next step from the conversation is useful — give it.\n"
        "- Only reply SKIP if this is clearly not a customer question (banter, the user talking to themselves, "
        "or pure filler with no ask).\n"
        "- If you truly lack the fact, give a short spoken deferral the user can say, not SKIP.\n"
    )


def sourced_system(meeting_type: str, user_asked: bool) -> str:
    if meeting_type == "interview":
        skip = (
            "- Always answer. Never reply SKIP."
            if user_asked
            else "- Only reply SKIP if nothing helps the interviewer."
        )
        return (
            "You are a live interviewer copilot. Docs/snippets may help evaluate or follow up. "
            "Write for the interviewer (signal, follow-ups, gaps) — not a customer pitch.\n\n"
            "Rules:\n"
            "- 2 to 5 short sentences or bullets.\n"
            "- Prefer snippets, notes, and transcript evidence.\n"
            "- Cite files in parentheses when used.\n"
            "- Do not invent candidate or product claims.\n"
            f"{skip}\n"
        )
    if meeting_type == "internalSync":
        skip = (
            "- Always answer. Never reply SKIP."
            if user_asked
            else "- Only reply SKIP if nothing actionable."
        )
        return (
            "You are a terse internal-meeting aide. Ground the answer in snippets/notes/transcript.\n\n"
            "Rules:\n"
            "- Prefer decisions, owners, clarify-asks, risks. 1 to 5 short sentences.\n"
            "- Cite files in parentheses when used.\n"
            "- Do not invent owners or commitments.\n"
            f"{skip}\n"
        )
    skip = (
        "- Always answer from snippets, notes, or transcript. Never reply SKIP."
        if user_asked
        else "- Only reply SKIP if nothing in snippets, notes, or transcript helps at all."
    )
    who = "The user asked a question" if user_asked else "The customer asked a question"
    return (
        f"You are a live call copilot. {who} and internal docs/snippets that may answer it "
        "are provided. Give the user a spoken-ready answer.\n\n"
        "Rules:\n"
        "- 2 to 5 short sentences the user can say out loud.\n"
        "- Prefer facts from snippets and notes. You may also use the recent conversation for "
        "continuity (what was already agreed on this call).\n"
        "- Do not invent prices, SLAs, or product claims absent from snippets/notes/transcript.\n"
        "- When a claim comes from a file, cite it in parentheses, e.g. (docs/foo.md).\n"
        "- If snippets are irrelevant but the transcript already answered it, say that briefly.\n"
        f"{skip}\n"
    )


def ask_label(meeting_type: str) -> str:
    if meeting_type == "interview":
        return "INTERVIEWER ASK"
    if meeting_type == "internalSync":
        return "MEETING ASK"
    return "CUSTOMER / USER ASK"


@dataclass(frozen=True)
class Probe:
    session: str
    question: str
    window: str
    user_asked: bool = False


@dataclass
class ProbeResult:
    probe: Probe
    quick: str = ""
    hit_files: list[str] = field(default_factory=list)
    sourced: str = ""
    verdict: str = "failed"


@dataclass(frozen=True)
class TranscriptLine:
    speaker: str
    time: str
    text: str

    @property
    def is_remote(self) -> bool:
        return self.speaker != "Me"

    def dialogue(self) -> str:
        return f"{self.speaker}: {self.text}"


def api_key() -> str | None:
    env = os.environ.get("XAI_API_KEY", "").strip()
    if env:
        return env
    try:
        proc = subprocess.run(
            [
                "security",
                "find-generic-password",
                "-s",
                "com.davidgeorgehope.cue",
                "-a",
                "xai",
                "-w",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError:
        return None
    if proc.returncode != 0:
        return None
    key = proc.stdout.strip()
    return key or None


def parse_session(path: Path) -> list[TranscriptLine]:
    lines: list[TranscriptLine] = []
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        m = LINE_RE.match(raw)
        if not m:
            continue
        text = m.group(3).strip()
        if not text or text.lower() == "(silence)":
            continue
        lines.append(TranscriptLine(speaker=m.group(1), time=m.group(2), text=text))
    return lines


def split_sentences(text: str) -> list[str]:
    parts = re.split(r"[.!?\n]+", text)
    return [p.strip() for p in parts if p.strip()]


def tidy_question(text: str) -> str:
    t = text.strip()
    if not t.endswith("?"):
        t += "?"
    return t


def detect_question(chunk: str, recent: str) -> str | None:
    cleaned = " ".join(chunk.split()).strip()
    if len(cleaned) < 8:
        return None
    if "?" in cleaned:
        head = cleaned[: cleaned.rfind("?") + 1]
        for sep in (".", "!", "\n"):
            if sep in head[:-1]:
                head = head[head.rfind(sep) + 1 :].lstrip()
        return tidy_question(head.rstrip("?").strip())
    sentences = split_sentences(cleaned)
    lower = cleaned.lower()
    if any(v in lower for v in QUESTION_VERBS):
        return tidy_question(sentences[-1] if sentences else cleaned)
    recent_sentences = split_sentences(recent)
    if recent_sentences:
        last = recent_sentences[-1]
        if "?" in last and len(last) >= 12:
            return tidy_question(last)
    return None


def is_substantive(question: str) -> bool:
    q = question.strip()
    if len(q) < 28:
        return False
    lower = q.lower()
    if any(s in lower for s in SKIP_QUESTION_SUBSTR):
        return False
    return True


def window_from(preceding: list[TranscriptLine]) -> str:
    words: list[str] = []
    for line in preceding:
        words.extend(line.dialogue().split())
    return " ".join(words[-WINDOW_WORDS:])


def extract_probes(session_path: Path) -> list[Probe]:
    lines = parse_session(session_path)
    probes: list[Probe] = []
    seen: set[str] = set()
    rolling = ""
    for i, line in enumerate(lines):
        rolling = (rolling + "\n" + line.dialogue()).strip()
        rolling = " ".join(rolling.split()[-WINDOW_WORDS:])
        if not line.is_remote:
            continue
        q = detect_question(line.text, rolling)
        if not q or not is_substantive(q):
            continue
        key = q.lower()
        if key in seen:
            continue
        seen.add(key)
        probes.append(
            Probe(
                session=session_path.name,
                question=q,
                window=window_from(lines[:i]),
            )
        )
    return probes


def session_window(session_path: Path) -> str:
    lines = parse_session(session_path)
    return window_from(lines)


def search_hits(
    question: str,
    roots: list[str],
    exclude: set[str],
    context: str = "",
) -> list[dict[str, str]]:
    candidates = keywords(question, limit=8)
    if len(candidates) < 3 and context:
        extra = [k for k in keywords(context, limit=8) if k not in candidates]
        candidates.extend(extra[-5:])
    if not candidates:
        return []

    def files_for(keyword: str) -> list[str]:
        escaped = re.escape(keyword)
        out = rg(["-il", "--type", "md", "--max-filesize", "300K", rf"\b{escaped}", *roots])
        return [
            line
            for line in out.splitlines()
            if line and Path(line).name not in exclude
        ]

    keyword_files: list[tuple[str, list[str]]] = []
    for keyword in candidates:
        files = files_for(keyword)
        if not files:
            continue
        if len(files) > MAX_DF and len(candidates) > 1:
            continue
        if len(files) > 2500:
            continue
        keyword_files.append((keyword, files))

    if not keyword_files:
        best: tuple[str, list[str]] | None = None
        for keyword in candidates:
            files = files_for(keyword)
            if not files:
                continue
            if best is None or len(files) < len(best[1]):
                best = (keyword, files)
        if best:
            keyword_files = [best]

    if not keyword_files:
        return []

    scores: dict[str, float] = {}
    for _, files in keyword_files:
        weight = 1.0 / len(files)
        for path in files:
            scores[path] = scores.get(path, 0.0) + weight + path_boost(path)

    top = sorted(scores.items(), key=lambda kv: (-kv[1], kv[0]))[:4]
    snippet_kws = sorted(keyword_files, key=lambda kf: len(kf[1]))[:3]
    pattern = "(" + "|".join(re.escape(k) for k, _ in snippet_kws) + ")"

    hits: list[dict[str, str]] = []
    for path, _score in top:
        out = rg(["-in", "-C", "2", "-m", "5", pattern, path], timeout=3.0)
        if not out:
            continue
        rel = path
        for root in roots:
            if path.startswith(root):
                rel = path[len(root) :].lstrip("/")
                break
        hits.append({"file": rel, "snippet": out[:1500]})
    return hits


def strip_skip(text: str) -> str:
    t = text.strip()
    upper = t.upper()
    if upper == "SKIP" or upper.startswith("SKIP\n"):
        return ""
    return t


def chat(system: str, user: str, max_tokens: int, key: str) -> str:
    payload = {
        "model": MODEL,
        "temperature": 0.2,
        "max_tokens": max_tokens,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
    }
    req = urllib.request.Request(
        API_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        body = json.loads(resp.read().decode("utf-8"))
    content = (
        body.get("choices", [{}])[0]
        .get("message", {})
        .get("content", "")
    )
    return strip_skip(content if isinstance(content, str) else "")


def quick_answer(
    question: str,
    window: str,
    notes: str,
    key: str,
    *,
    meeting_type: str,
    user_asked: bool,
) -> str:
    label = ask_label(meeting_type)
    user = (
        f"CONTEXT / NOTES:\n"
        f"{notes if notes else '(none provided)'}\n\n"
        f"RECENT TRANSCRIPT:\n"
        f"{window[-1800:]}\n\n"
        f"{label}:\n"
        f"{question}"
    )
    return chat(quick_system(meeting_type, user_asked), user, 180, key)


def sourced_answer(
    question: str,
    snippets: str,
    notes: str,
    window: str,
    key: str,
    *,
    meeting_type: str,
    user_asked: bool,
) -> str:
    notes_bit = notes[:1200] if notes else "(none)"
    label = ask_label(meeting_type)
    user = (
        f"{label}:\n"
        f"{question}\n\n"
        f"RECENT CONVERSATION (for what the question refers to):\n"
        f"{window[-1200:]}\n\n"
        f"USER'S NOTES:\n"
        f"{notes_bit}\n\n"
        f"REPO/DOCS SNIPPETS:\n"
        f"{snippets[:7000]}"
    )
    return chat(sourced_system(meeting_type, user_asked), user, 320, key)


def classify(quick: str, sourced: str, *, failed: bool) -> str:
    if failed:
        return "failed"
    if quick:
        return "answered"
    if sourced:
        return "sourced_only"
    return "skipped"


def knowledge_roots() -> list[str]:
    roots: list[str] = []
    if root := os.environ.get("CUE_SOURCE_ROOT", "").strip():
        roots.append(str(Path(root).expanduser()))
    if SESSIONS_DIR.exists():
        roots.append(str(SESSIONS_DIR))
    return roots


def run_probe(
    probe: Probe,
    notes: str,
    roots: list[str],
    key: str,
    meeting_type: str,
) -> ProbeResult:
    result = ProbeResult(probe=probe)
    user_asked = probe.user_asked
    quick_ok = False
    try:
        result.quick = quick_answer(
            probe.question,
            probe.window,
            notes,
            key,
            meeting_type=meeting_type,
            user_asked=user_asked,
        )
        quick_ok = True
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, json.JSONDecodeError, KeyError):
        result.quick = ""

    hits = search_hits(probe.question, roots, exclude={probe.session}, context=probe.window)
    result.hit_files = [h["file"] for h in hits]
    sourced_ok = False
    if hits:
        snippets = "\n\n---\n\n".join(
            f"FILE: {h['file']}\n{h['snippet']}" for h in hits
        )
        try:
            result.sourced = sourced_answer(
                probe.question,
                snippets,
                notes,
                probe.window,
                key,
                meeting_type=meeting_type,
                user_asked=user_asked,
            )
            sourced_ok = True
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, json.JSONDecodeError, KeyError):
            result.sourced = ""

    if result.quick or result.sourced:
        result.verdict = classify(result.quick, result.sourced, failed=False)
    elif quick_ok or sourced_ok:
        result.verdict = "skipped"
    else:
        result.verdict = "failed"
    return result


def trunc(text: str, n: int) -> str:
    t = " ".join(text.split())
    return t if len(t) <= n else t[: n - 1] + "…"


def session_files(session: str | None) -> list[Path]:
    if not SESSIONS_DIR.exists():
        return []
    if session:
        path = SESSIONS_DIR / session
        return [path] if path.is_file() else []
    return sorted(
        p
        for p in SESSIONS_DIR.glob("call-*.md")
        if not p.name.endswith(".wrap.md")
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Prove Cue answers on real call transcripts.")
    parser.add_argument("--session", help="Basename only, e.g. call-2026-08-24_11-43-10.md")
    parser.add_argument("--limit", type=int, default=8, help="Max probes to run (default 8)")
    parser.add_argument(
        "--min-answered",
        type=int,
        default=None,
        help="PASS threshold (default 3, or 1 with --ask)",
    )
    parser.add_argument("--notes", default="", help="Optional CONTEXT / NOTES string")
    parser.add_argument(
        "--meeting-type",
        default="sales",
        choices=sorted(MEETING_ALIASES.keys()),
        help="Prompt flavor (default sales)",
    )
    parser.add_argument(
        "--ask",
        default="",
        help="Force user-ask path (no SKIP-as-non-customer) against session window",
    )
    args = parser.parse_args()
    meeting_type = MEETING_ALIASES[args.meeting_type.lower()]
    min_answered = args.min_answered if args.min_answered is not None else (1 if args.ask.strip() else 3)

    key = api_key()
    if not key:
        print(
            "Missing XAI_API_KEY (env or keychain com.davidgeorgehope.cue / xai).",
            file=sys.stderr,
        )
        return 1

    files = session_files(args.session)
    if not files:
        target = args.session or str(SESSIONS_DIR)
        print(f"No call-*.md sessions found at {target}", file=sys.stderr)
        return 1

    roots = knowledge_roots()
    probes: list[Probe] = []
    ask_text = args.ask.strip()
    if ask_text:
        path = files[0]
        probes = [
            Probe(
                session=path.name,
                question=ask_text,
                window=session_window(path),
                user_asked=True,
            )
        ]
    else:
        for path in files:
            probes.extend(extract_probes(path))
            if len(probes) >= args.limit:
                break
        probes = probes[: args.limit]
    if not probes:
        print("No question probes extracted from sessions.", file=sys.stderr)
        return 1

    results = []
    print(
        f"meeting_type={meeting_type} ask={'yes' if ask_text else 'no'}",
        flush=True,
    )
    print(
        f"{'session':<28} {'verdict':<14} {'hits':>4}  question / answer",
        flush=True,
    )
    print("-" * 96, flush=True)
    for p in probes:
        r = run_probe(p, args.notes, roots, key, meeting_type)
        results.append(r)
        ans = r.quick or r.sourced or ""
        print(
            f"{r.probe.session:<28} {r.verdict:<14} {len(r.hit_files):>4}  "
            f"{trunc(r.probe.question, 80)}",
            flush=True,
        )
        print(f"{'':28} {'':14} {'':4}  → {trunc(ans, 120)}", flush=True)

    answered_n = sum(1 for r in results if r.quick or r.sourced)

    print("-" * 96, flush=True)
    by = {v: 0 for v in ("answered", "sourced_only", "skipped", "failed")}
    for r in results:
        by[r.verdict] = by.get(r.verdict, 0) + 1
    print(
        f"probes={len(results)} non_empty={answered_n} "
        f"answered={by['answered']} sourced_only={by['sourced_only']} "
        f"skipped={by['skipped']} failed={by['failed']} "
        f"min_answered={min_answered}"
    )

    payload = {
        "meeting_type": meeting_type,
        "user_asked": bool(ask_text),
        "min_answered": min_answered,
        "non_empty": answered_n,
        "roots": roots,
        "results": [
            {
                "session": r.probe.session,
                "question": r.probe.question,
                "user_asked": r.probe.user_asked,
                "window_chars": len(r.probe.window),
                "quick": r.quick,
                "hit_files": r.hit_files,
                "sourced": r.sourced,
                "verdict": r.verdict,
            }
            for r in results
        ],
    }
    OUT_JSON.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {OUT_JSON}")

    ok = answered_n >= min_answered
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
