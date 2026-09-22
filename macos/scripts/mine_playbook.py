#!/usr/bin/env python3
"""Grow Cue's playbook from where it performs badly.

Failure ledger in → playbook entries out. For each question Cue scored ≤1 on
(prove_from_eval results), find other calls where a customer asked the same
thing, read how the vendor side (SA or AE) answered, and synthesise one dated, sourced Q&A entry
that Cue's retrieval will hit next time.

  1. Cluster ledger questions into topics (grok-4.6) so "multiplayer?" asked
     five ways becomes one entry.
  2. Per topic, grok-4.6 proposes subject/aspect search terms; SQL finds
     transcript_chunks where an External speaker used both, restricted to
     calls OLDER than --holdout-days so the eval set stays held out.
  3. Pull ±2 min of Me/Them utterances around each hit (one query per topic).
  4. grok-4.6 keeps only true matches, extracts each rep's answer, and writes
     the entry: canonical question, spoken-ready answer, as_of, confidence,
     disagreements, pitfalls (Cue's own wrong answers from the ledger),
     sources (call ids + dates only — no customer names).

No embeddings: the stored vectors are text-embedding-3-small, which we can't
reproduce, so this is keyword prefilter + LLM rerank.

Requires the Databricks CLI; --profile is required and never guessed.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

_SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(_SCRIPTS))

from mine_call_questions import _xai_chat, databricks_query  # noqa: E402
from prove_answers import MODEL, _load_dotenv, api_key  # noqa: E402
from prove_from_eval import is_technical  # noqa: E402

PLAYBOOK_DIR = Path.home() / "Library/Application Support/Cue/knowledge/playbook"
LEDGER_OUT = Path.home() / "Library/Application Support/Cue/eval/failure-ledger.json"


def llm_json(system: str, user: str, key: str, max_tokens: int = 1500) -> dict:
    payload = {
        "model": MODEL, "temperature": 0.1, "max_tokens": max_tokens, "reasoning_effort": "low",
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
    }
    content = _xai_chat(payload, key) or ""
    if content.startswith("```"):
        content = content.strip("`").removeprefix("json").strip()
    try:
        return json.loads(content)
    except json.JSONDecodeError as e:
        print(f"  ! bad JSON from model ({e}); tail: {content[-160:]!r}", file=sys.stderr, flush=True)
        return {}


# ---------------------------------------------------------------- ledger

def load_ledger(results_paths: list[Path], max_score: int, technical_only: bool = False) -> list[dict]:
    """Merge prove_from_eval result files (later files override earlier by
    reference question) and keep the poorly scored ones."""
    merged: dict[str, dict] = {}
    for p in results_paths:
        for r in json.loads(p.read_text())["results"]:
            merged[r["reference_question"]] = r
    if technical_only:
        merged = {k: r for k, r in merged.items()
                  if is_technical({"category": r.get("category"), "question": r["reference_question"]})}
    ledger = [
        {
            "question": r["reference_question"],
            "score": r["answer_score"],
            "label": r["label"],
            "cue_answer": r["cue_answer"],
            "rationale": r["rationale"],
            "invented_claims": r.get("invented_claims", []),
        }
        for r in merged.values()
        if r["answer_score"] <= max_score
    ]
    LEDGER_OUT.parent.mkdir(parents=True, exist_ok=True)
    LEDGER_OUT.write_text(json.dumps({"generated": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                                      "entries": ledger}, indent=2) + "\n")
    return ledger


CLUSTER_SYSTEM = """You organise customer questions from vendor calls (SA and AE led) into topics for a knowledge base.
One topic = ONE intent that a single short answer covers. Merge only true paraphrases; a
question with two intents becomes two topics (a topic may have a single member). Never write
compound canonical questions joined by "and"/commas. Skip questions only the rep could answer
(their own follow-ups, "did you send the form", "who should we meet", internal status/ETAs).

Return only valid JSON:
{"topics": [{"canonical_question": "one clear single-intent product question", "member_indexes": [0, 4],
             "subject_terms": ["grokbot", "grok bot"],
             "aspect_terms": ["cloud", "locally", "local machine", "vm", "on-prem", "home machine"]}],
 "skipped_indexes": [7]}

Terms are case-insensitive substring matches on spoken transcripts, so use words people say
aloud. subject_terms: 1-4 names for the product/feature (include spelling variants people
say, e.g. "grokbot", "grok bot"). aspect_terms: 3-8 phrases distinctive to THIS intent — no
generic words ("app", "use", "cursor", "install", "work") that would match unrelated chatter."""


def cluster(ledger: list[dict], key: str) -> list[dict]:
    numbered = "\n".join(f"[{i}] {e['question']}" for i, e in enumerate(ledger))
    out = llm_json(CLUSTER_SYSTEM, f"QUESTIONS:\n{numbered}", key, max_tokens=8000)
    topics = out.get("topics", [])
    for t in topics:
        t["members"] = [ledger[i] for i in t.get("member_indexes", []) if 0 <= i < len(ledger)]
    kept = [t for t in topics if t.get("members") and t.get("subject_terms") and t.get("aspect_terms")]
    kept.sort(key=lambda t: -len(t["members"]))
    return kept


# ---------------------------------------------------------------- search

def _alternation(terms: list[str]) -> str:
    return "(" + "|".join(re.escape(t.strip()) for t in terms if t.strip()) + ")"


def find_excerpts(topic: dict, profile: str, table_prefix: str, holdout_days: int, lookback_days: int, limit: int) -> list[dict]:
    t = table_prefix
    subj = _alternation(topic["subject_terms"])
    aspects = [a.strip() for a in topic["aspect_terms"] if a.strip()]
    # A chunk where an External line mentions the subject and an External
    # line mentions an aspect; ranked by how many distinct aspects the
    # customer used so specific asks beat chatter that shares one word.
    # SQL string escaping: \\( for the literal paren.
    ext_line = r"(?im)^[^\\n]*\\(External[^\\n]*"
    aspect_hits = " + ".join(f"CASE WHEN tc.text RLIKE '{ext_line}{_alternation([a])}' THEN 1 ELSE 0 END" for a in aspects)
    sql = f"""
    WITH hits AS (
      SELECT tc.call_id, tc.start_ms AS hit_ms, ({aspect_hits}) AS score
      FROM {t}.transcript_chunks tc
      JOIN {t}.calls c ON c.call_id = tc.call_id
      WHERE c.started < date_sub(current_date(), {int(holdout_days)})
        AND c.started >= date_sub(current_date(), {int(lookback_days)})
        AND tc.text RLIKE '{ext_line}{subj}'
        AND tc.text RLIKE '{ext_line}{_alternation(aspects)}'
      ORDER BY score DESC, c.started DESC
      LIMIT {int(limit)}
    )
    SELECT h.call_id, c.started, h.hit_ms, h.score,
           array_join(transform(array_sort(collect_list(struct(u.start_ms AS ms,
             concat(CASE WHEN s.affiliation_norm = 'internal' THEN 'Me' ELSE 'Them' END, ': ', u.text) AS line))),
             x -> x.line), '\\n') AS excerpt
    FROM hits h
    JOIN {t}.calls c ON c.call_id = h.call_id
    JOIN {t}.utterances u ON u.call_id = h.call_id
         AND u.start_ms BETWEEN h.hit_ms - 30000 AND h.hit_ms + 150000
    JOIN {t}.speaker_map s ON s.call_id = u.call_id AND s.speaker_id = u.speaker_id
    GROUP BY h.call_id, c.started, h.hit_ms, h.score
    ORDER BY h.score DESC, c.started DESC
    """
    rows = databricks_query(sql, profile)
    # One excerpt per call: chunks overlap, so the same ask hits twice.
    seen: set[str] = set()
    out = []
    for r in rows:
        if r["call_id"] in seen:
            continue
        seen.add(r["call_id"])
        out.append({"call_id": r["call_id"], "date": r["started"][:10], "excerpt": r["excerpt"][:3500]})
    return out


# ---------------------------------------------------------------- synthesis

SYNTH_SYSTEM = """You write one knowledge-base entry for a live call copilot from real call excerpts.
"Me" is the vendor side (a solutions architect or account exec); "Them" is a customer. Excerpts were
found by keyword and may be irrelevant — judge each. For technical questions keep the concrete
mechanism, setting, or limit the speaker gave; do not smooth it into marketing language.

Return only valid JSON:
{
  "matches": [{"excerpt_index": 0, "customer_ask": "…", "rep_answer": "faithful condensation",
               "rep_answer_quality": "strong|adequate|weak"}],
  "answer": "2-4 spoken-ready sentences the vendor side can say, built ONLY from matched rep answers; \
'' if no usable matches",
  "as_of": "YYYY-MM-DD of the most recent matched excerpt, or ''",
  "confidence": "high|medium|low",
  "disagreements": ["where matched reps gave conflicting answers, stated neutrally"],
  "caveats": ["time-sensitive or conditional parts of the answer"]
}

- A match means the customer asked the same question as CANONICAL QUESTION (same intent).
- Do not use anything from irrelevant excerpts. Do not use general knowledge. If reps only
  deferred, say so in the answer ("reps typically take this offline; …") rather than inventing.
- confidence: high = 2+ reps agree with substance; medium = one substantive answer;
  low = only deferrals or thin/conflicting answers.
- No customer or company names anywhere in the output."""


def synthesize(topic: dict, excerpts: list[dict], key: str) -> dict:
    blocks = "\n\n".join(
        f"=== EXCERPT {i} (call date {e['date']})\n{e['excerpt']}" for i, e in enumerate(excerpts)
    )
    user = f"CANONICAL QUESTION:\n{topic['canonical_question']}\n\nEXCERPTS:\n{blocks}"
    return llm_json(SYNTH_SYSTEM, user, key, max_tokens=1800)


def slugify(text: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return s[:70] or "entry"


def write_entry(topic: dict, synth: dict, excerpts: list[dict]) -> Path | None:
    answer = (synth.get("answer") or "").strip()
    matches = synth.get("matches", [])
    if not answer or not matches:
        return None
    pitfalls = []
    for m in topic["members"]:
        if m["score"] == 0 and m["cue_answer"]:
            why = m["rationale"].strip()
            pitfalls.append(f"- Cue said: \"{m['cue_answer'][:220].strip()}\" — {why}")
        for claim in m.get("invented_claims", [])[:2]:
            pitfalls.append(f"- Unsupported claim to avoid: {claim}")
    matched = {m["excerpt_index"]: m for m in matches if isinstance(m.get("excerpt_index"), int)}
    sources = [f"- {excerpts[i]['date']} · call {excerpts[i]['call_id']} · rep answer {matched[i].get('rep_answer_quality', '?')}"
               for i in sorted(matched) if 0 <= i < len(excerpts)]
    variants = sorted({m["question"] for m in topic["members"]} - {topic["canonical_question"]})

    md = [f"# {topic['canonical_question']}", ""]
    md.append(f"as_of: {synth.get('as_of') or 'unknown'} · confidence: {synth.get('confidence', 'low')} · sources: {len(sources)} calls")
    if variants:
        md += ["", "Also asked as:"] + [f"- {v}" for v in variants]
    md += ["", "## Answer", "", answer]
    if synth.get("caveats"):
        md += ["", "## Caveats"] + [f"- {c}" for c in synth["caveats"]]
    if synth.get("disagreements"):
        md += ["", "## Disagreements between reps"] + [f"- {d}" for d in synth["disagreements"]]
    if pitfalls:
        md += ["", "## Pitfalls (do not say)"] + pitfalls
    md += ["", "## Sources"] + sources
    md += ["", f"_Generated {datetime.now(timezone.utc).date()} by mine_playbook.py from Gong transcripts in Databricks._", ""]

    PLAYBOOK_DIR.mkdir(parents=True, exist_ok=True)
    path = PLAYBOOK_DIR / f"{slugify(topic['canonical_question'])}.md"
    path.write_text("\n".join(md), encoding="utf-8")
    return path


# ---------------------------------------------------------------- main

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--results", type=Path, nargs="+", required=True,
                    help="prove_from_eval results JSON(s); later files override earlier ones")
    ap.add_argument("--max-score", type=int, default=1, help="ledger = answers scoring at most this (default 1)")
    ap.add_argument("--profile", required=True, help="Databricks CLI profile")
    ap.add_argument("--table-prefix", default="dev.rperry")
    ap.add_argument("--holdout-days", type=int, default=30, help="never mine calls newer than this (eval split)")
    ap.add_argument("--lookback-days", type=int, default=365)
    ap.add_argument("--excerpts", type=int, default=14, help="max candidate calls per topic")
    ap.add_argument("--limit-topics", type=int, default=0)
    ap.add_argument("--technical", action="store_true", help="only mine technical failures (see prove_from_eval --technical)")
    args = ap.parse_args()

    key = api_key()
    if not key:
        print("Missing XAI_API_KEY", file=sys.stderr)
        return 1
    _load_dotenv()

    ledger = load_ledger(args.results, args.max_score, technical_only=args.technical)
    print(f"ledger: {len(ledger)} questions scoring ≤{args.max_score}  → {LEDGER_OUT}")
    topics = cluster(ledger, key)
    if args.limit_topics:
        topics = topics[: args.limit_topics]
    print(f"{len(topics)} topics after clustering\n")

    written, skipped = [], []
    for i, topic in enumerate(topics, 1):
        q = topic["canonical_question"]
        print(f"[{i}/{len(topics)}] {q}", flush=True)
        print(f"     terms: {topic['subject_terms']} × {topic['aspect_terms']}", flush=True)
        excerpts = find_excerpts(topic, args.profile, args.table_prefix, args.holdout_days, args.lookback_days, args.excerpts)
        print(f"     {len(excerpts)} candidate calls", flush=True)
        if not excerpts:
            skipped.append((q, "no candidates"))
            continue
        synth = synthesize(topic, excerpts, key)
        path = write_entry(topic, synth, excerpts)
        if path:
            print(f"     ✓ {len(synth.get('matches', []))} matches · {synth.get('confidence')} · {path.name}", flush=True)
            written.append(path)
        else:
            skipped.append((q, "no true matches / no answer"))
            print("     – no usable matches", flush=True)

    print(f"\nwrote {len(written)} playbook entries → {PLAYBOOK_DIR}")
    if skipped:
        print(f"skipped {len(skipped)}:")
        for q, why in skipped:
            print(f"  - {q[:90]}  ({why})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
