#!/usr/bin/env python3
"""Pull full Gong call transcripts from Databricks as Cue replay files.

Picks calls from the mined eval set (call-questions.json) ranked by how many
technical questions they contain, fetches every utterance for each, and writes
them in Cue's session format so the app can replay them as if live:

  CUE_REPLAY_FILE=~/Library/Application\\ Support/Cue/replays/<file>.md \\
  CUE_REPLAY_SPEED=3 CUE_REPLAY_TYPE=technical open -a ~/Applications/Cue.app

Usage:
  python3 fetch_call_transcript.py --profile <p> [--count 2] [--call-id ID ...] [--list]
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mine_call_questions import DEFAULT_OUT as EVAL_JSON, databricks_query  # noqa: E402
from prove_from_eval import is_technical  # noqa: E402

REPLAYS = Path.home() / "Library/Application Support/Cue/replays"


def rank_calls(records: list[dict]) -> list[tuple[str, dict, int, int]]:
    """(call_id, sample record, technical question count, total) — most technical first."""
    by_call: dict[str, list[dict]] = {}
    for r in records:
        by_call.setdefault(r["call_id"], []).append(r)
    ranked = []
    for cid, recs in by_call.items():
        tech = sum(1 for r in recs if is_technical(r))
        ranked.append((cid, recs[0], tech, len(recs)))
    ranked.sort(key=lambda x: (-x[2], -x[3]))
    return ranked


def clock(ms: int) -> str:
    s = int(ms) // 1000
    return f"{s // 3600:02d}:{(s % 3600) // 60:02d}:{s % 60:02d}"


def slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", (text or "call").lower()).strip("-")[:60]


def fetch(call_id: str, meta: dict, profile: str, table_prefix: str) -> Path:
    sql = f"""
    SELECT u.start_ms, u.text,
           CASE WHEN s.affiliation_norm = 'internal' THEN 'Me' ELSE 'Them' END AS side
    FROM {table_prefix}.utterances u
    JOIN {table_prefix}.speaker_map s ON s.call_id = u.call_id AND s.speaker_id = u.speaker_id
    WHERE u.call_id = :call_id
    ORDER BY u.start_ms
    """
    rows = databricks_query(sql, profile, {"call_id": call_id})
    if not rows:
        raise SystemExit(f"no utterances for call {call_id}")
    REPLAYS.mkdir(parents=True, exist_ok=True)
    started = (meta.get("call_started") or "")[:10]
    dest = REPLAYS / f"{started or 'undated'}-{slug(meta.get('call_title', ''))}.md"
    sides = Counter(r["side"] for r in rows)
    with dest.open("w", encoding="utf-8") as f:
        f.write(f"# {meta.get('call_title', call_id)}\n\n")
        f.write(f"call_id: {call_id}  \nstarted: {meta.get('call_started', '')}  \n")
        f.write(f"url: {meta.get('call_url', '')}  \nutterances: {len(rows)} (Them {sides['Them']}, Me {sides['Me']})\n\n")
        for r in rows:
            text = " ".join(str(r["text"]).split())
            if text:
                f.write(f"- **{r['side']}** ({clock(r['start_ms'])}): {text}\n")
    return dest


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--profile", required=True, help="Databricks CLI profile (never auto-selected)")
    ap.add_argument("--table-prefix", default="dev.rperry")
    ap.add_argument("--eval", type=Path, default=EVAL_JSON)
    ap.add_argument("--count", type=int, default=2, help="how many of the most technical calls to fetch")
    ap.add_argument("--call-id", nargs="*", default=[], help="fetch these specific calls instead")
    ap.add_argument("--list", action="store_true", help="only print the ranking")
    args = ap.parse_args()

    records = json.loads(args.eval.read_text())["records"]
    ranked = rank_calls(records)
    print(f"{len(ranked)} calls in eval set; most technical first:")
    for cid, meta, tech, total in ranked[:10]:
        print(f"  {tech:2d}/{total:2d} technical  {meta.get('call_started', '')[:10]}  {meta.get('call_title', '')[:70]}  [{cid}]")
    if args.list:
        return 0

    if args.call_id:
        picks = [(cid, next((m for c, m, _, _ in ranked if c == cid), {"call_title": cid}), 0, 0) for cid in args.call_id]
    else:
        picks = ranked[: args.count]
    for cid, meta, tech, total in picks:
        dest = fetch(cid, meta, args.profile, args.table_prefix)
        print(f"wrote {dest}")
        print(f"  replay: CUE_REPLAY_FILE='{dest}' CUE_REPLAY_SPEED=3 CUE_REPLAY_TYPE=technical open -a ~/Applications/Cue.app")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
