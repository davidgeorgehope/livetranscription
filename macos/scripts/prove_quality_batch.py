#!/usr/bin/env python3
"""Batch quality proof for Cue asks against real sessions.

Writes /tmp/cue-quality-batch.json with per-question answers + quality flags.
Exit 0 when every probe is non-empty and free of deferral markers.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

_SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(_SCRIPTS))

from prove_answers import (  # noqa: E402
    OUT_JSON,
    Probe,
    api_key,
    knowledge_roots,
    quality_flags,
    run_probe,
    session_window,
)

BATCH_OUT = Path("/tmp/cue-quality-batch.json")

INTERVIEW_ASKS = [
    "Summarize the candidate's core problem statement in 3 bullets.",
    "What success metrics did the candidate propose for this investment?",
    "What is their approach to onboarding a new repo before rewriting rules?",
    "Where are gaps or soft spots I should probe next?",
    "Suggest one sharp follow-up about deterministic gates vs agent checks.",
    "How do they think about product builders vs factory builders?",
]

SALES_ASKS = [
    "How do I validate that Growth Path isn't on Grok Bot yet?",
    "Customer says the team didn't show up after admin setup — what should I say?",
    "Walk me through what to click for team admin vs org admin on Grok Bot sign-in.",
    "They skipped selecting teams in the wizard — how do we fix that?",
]


def main() -> int:
    key = api_key()
    if not key:
        print("Missing API key", file=sys.stderr)
        return 1
    roots = knowledge_roots()
    sessions = Path.home() / "Library/Application Support/Cue/sessions"
    interview = sessions / "call-2026-08-25_14-05-30.md"
    sales = sessions / "call-2026-08-25_11-09-09.md"
    if not interview.is_file() or not sales.is_file():
        print("Missing session files", file=sys.stderr)
        return 1

    cases: list[tuple[str, Path, list[str]]] = [
        ("interview", interview, INTERVIEW_ASKS),
        ("sales", sales, SALES_ASKS),
    ]

    all_results = []
    great = 0
    total = 0
    for meeting_type, path, asks in cases:
        window = session_window(path, meeting_type)
        print(f"\n=== {meeting_type} {path.name} window_chars={len(window)} ===", flush=True)
        for ask in asks:
            total += 1
            probe = Probe(
                session=path.name,
                question=ask,
                window=window,
                user_asked=True,
            )
            r = run_probe(probe, "", roots, key, meeting_type)
            best = r.sourced or r.quick
            flags = quality_flags(best)
            is_great = bool(best) and "empty" not in flags and "deferral" not in flags and "too_short" not in flags
            if is_great:
                great += 1
            print(f"\nQ: {ask}", flush=True)
            print(f"hits: {r.hit_files[:4]}", flush=True)
            print(f"flags: {flags} great={is_great}", flush=True)
            print(f"→ {(best or '')[:400]}", flush=True)
            all_results.append(
                {
                    "meeting_type": meeting_type,
                    "session": path.name,
                    "question": ask,
                    "hit_files": r.hit_files,
                    "quick": r.quick,
                    "sourced": r.sourced,
                    "verdict": r.verdict,
                    "quality_flags": flags,
                    "great": is_great,
                }
            )

    payload = {
        "roots": roots,
        "total": total,
        "great": great,
        "results": all_results,
    }
    BATCH_OUT.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    # also mirror last prove json
    OUT_JSON.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(f"\nSUMMARY great={great}/{total} wrote {BATCH_OUT}", flush=True)
    ok = great == total and total > 0
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
