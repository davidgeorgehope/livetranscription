#!/usr/bin/env python3
"""Turn mined call questions into a pre-call prep brief for Cue.

Input is the JSON written by mine_call_questions.py (questions, what the SA or AE
actually answered, quality, status). Output is markdown shaped for Cue's prep
slot: a short top-facts block first (prompts see the first few thousand chars),
then one self-contained section per theme so ripgrep can lift the relevant one.

Usage:
  python3 build_prep_brief.py --questions /tmp/q.json --topic "Grok Bot security" \\
      --out ~/Library/Application\\ Support/Cue/prep/current/grok-bot-security-brief.md
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mine_call_questions import _xai_chat, api_key  # noqa: E402

MODEL = "grok-4.6"

SYSTEM = """You write pre-call briefs for a solutions architect at the vendor. The input is every
question customers asked on past calls about TOPIC, with what our SA or AE answered, how
good that answer was, and whether it was deferred or left unanswered.

Write a brief in markdown that lets the SA answer the same questions well tomorrow.

Format, in this order:

# <TOPIC> — prep brief
as_of: <today> · sources: <n> calls, <m> questions

## Top facts (say these)
8-14 one-line bullets. The concrete claims we have made consistently and confidently:
mechanisms, defaults, what ships vs roadmap, what we can share (reports, docs). Each bullet
is a full sentence the SA can say out loud. No hedging words unless the fact is itself
uncertain.

## Themes
One `### <theme>` per cluster of questions (6-10 themes). Inside each:
- **They ask:** 2-4 real question phrasings, condensed.
- **Say:** the best answer we have given, rewritten as 2-4 spoken sentences. Sentence one is
  the direct answer. Merge the strongest points across calls. Plain words.
- **Caveats:** 1-3 bullets — what we deferred, promised to follow up, or must not commit to.
- **Weak spots:** only if present — questions where our answer was weak, deferred, or absent.
  Phrase as "Be ready for: <question>".

## Commitments already made
Bullets of concrete promises our side made on these calls (reports to send, follow-ups,
roadmap statements), so the SA does not contradict them.

## Do not say
Bullets of claims that were wrong, contradicted across calls, or over-committed.

Rules: facts only from the input; never invent. Do not name customers or people; refer to
"a customer" or "a security team". Keep the whole brief under 9000 characters."""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--questions", type=Path, required=True)
    ap.add_argument("--topic", required=True)
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()

    data = json.loads(args.questions.read_text())
    records = data["records"] if isinstance(data, dict) else data
    calls = {r["call_id"] for r in records}
    lines = []
    for r in records:
        lines.append(
            f"- [{(r.get('call_started') or '')[:10]}] [{r.get('category', '?')}/{r.get('status', '?')}/"
            f"{r.get('answer_quality') or 'n/a'}] Q: {r['question']}\n"
            f"  A: {r.get('rep_answer') or '(no answer given)'}"
        )
    user = (
        f"TOPIC: {args.topic}\nTODAY: {date.today().isoformat()}\n"
        f"{len(calls)} calls, {len(records)} questions.\n\n" + "\n".join(lines)
    )
    key = api_key()
    if not key:
        raise SystemExit("Missing XAI_API_KEY")
    print(f"synthesizing from {len(records)} questions across {len(calls)} calls…", flush=True)
    text = _xai_chat({
        "model": MODEL,
        "temperature": 0.2,
        "max_tokens": 6000,
        "messages": [{"role": "system", "content": SYSTEM}, {"role": "user", "content": user}],
    }, key)
    if not text:
        raise SystemExit("xAI returned nothing")
    text = text.strip()
    if text.startswith("```"):
        text = text.split("\n", 1)[1].rsplit("```", 1)[0]
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(text.strip() + "\n", encoding="utf-8")
    print(f"wrote {args.out} ({len(text)} chars)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
