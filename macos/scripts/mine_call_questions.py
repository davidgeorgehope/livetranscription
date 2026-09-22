#!/usr/bin/env python3
"""Mine real customer questions out of recorded calls to build a Cue eval set.

Given Me/Them transcripts, grok-4.6 picks out the questions the vendor side
(SA or AE — "Me") was expected to answer and what they actually said. Each
record carries the dialogue window Cue would have seen at that moment, so the
eval can replay the analyst + answer pipeline and grade against the real answer instead
of a "not empty / not a deferral" heuristic.

Input — one of:
  --databricks --profile P   Gong transcripts synced to Unity Catalog
                     (dev.rperry.calls / utterances / speaker_map). Uses the
                     Databricks CLI; --profile is required, never guessed.
  --from-json PATH   transcripts already fetched some other way. Shape:
                     {"calls": [{"id": "…", "title": "…", "started": "ISO",
                                 "url": "…",
                                 "lines": [{"speaker": "Me|Them", "text": "…"}]}]}
  --gong             pull directly from Gong's REST API. Needs
                     GONG_ACCESS_KEY / GONG_ACCESS_KEY_SECRET in .env
                     (optional GONG_BASE_URL region URL).
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

_SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(_SCRIPTS))

from prove_answers import API_URL, MODEL, _load_dotenv, api_key  # noqa: E402

DEFAULT_OUT = Path.home() / "Library/Application Support/Cue/eval/call-questions.json"
WINDOW_WORDS = 400  # matches MeetingType.sales.recentWindowWordBudget
CHUNK_WORDS = 7000
CHUNK_OVERLAP_LINES = 12


class Gong:
    def __init__(self) -> None:
        key = os.environ.get("GONG_ACCESS_KEY", "").strip()
        secret = os.environ.get("GONG_ACCESS_KEY_SECRET", "").strip()
        if not key or not secret:
            raise SystemExit(
                "Missing GONG_ACCESS_KEY / GONG_ACCESS_KEY_SECRET. Create one in Gong: "
                "Company Settings → Ecosystem → API, then add both to .env."
            )
        self.base = os.environ.get("GONG_BASE_URL", "https://api.gong.io").rstrip("/")
        self.auth = base64.b64encode(f"{key}:{secret}".encode()).decode()

    def _call(self, method: str, path: str, body: dict | None = None, params: dict | None = None) -> dict:
        url = f"{self.base}{path}"
        if params:
            url += "?" + "&".join(f"{k}={urllib.request.quote(str(v))}" for k, v in params.items() if v is not None)
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method, headers={
            "Authorization": f"Basic {self.auth}",
            "Content-Type": "application/json",
        })
        for attempt in range(4):
            try:
                with urllib.request.urlopen(req, timeout=60) as r:
                    return json.load(r)
            except urllib.error.HTTPError as e:
                # Gong rate-limits at 3 req/s; back off and retry.
                if e.code == 429 and attempt < 3:
                    time.sleep(1.5 * (attempt + 1))
                    continue
                raise SystemExit(f"Gong {method} {path} → HTTP {e.code}: {e.read()[:300].decode(errors='replace')}")
        raise SystemExit("Gong: too many retries")

    def list_calls(self, days: int, max_calls: int) -> list[dict]:
        now = datetime.now(timezone.utc)
        params = {
            "fromDateTime": (now - timedelta(days=days)).isoformat(timespec="seconds"),
            "toDateTime": now.isoformat(timespec="seconds"),
        }
        calls: list[dict] = []
        cursor = None
        while len(calls) < max_calls:
            page = self._call("GET", "/v2/calls", params={**params, "cursor": cursor})
            calls.extend(page.get("calls", []))
            cursor = page.get("records", {}).get("cursor")
            if not cursor:
                break
            time.sleep(0.4)
        calls.sort(key=lambda c: c.get("started", ""), reverse=True)
        return calls[:max_calls]

    def parties(self, call_ids: list[str]) -> dict[str, list[dict]]:
        out: dict[str, list[dict]] = {}
        for i in range(0, len(call_ids), 50):
            body = {
                "filter": {"callIds": call_ids[i:i + 50]},
                "contentSelector": {"exposedFields": {"parties": True}},
            }
            cursor = None
            while True:
                if cursor:
                    body["cursor"] = cursor
                page = self._call("POST", "/v2/calls/extensive", body)
                for c in page.get("calls", []):
                    out[c["metaData"]["id"]] = c.get("parties", [])
                cursor = page.get("records", {}).get("cursor")
                if not cursor:
                    break
            time.sleep(0.4)
        return out

    def transcripts(self, call_ids: list[str]) -> dict[str, list[dict]]:
        out: dict[str, list[dict]] = {}
        for i in range(0, len(call_ids), 50):
            body = {"filter": {"callIds": call_ids[i:i + 50]}}
            cursor = None
            while True:
                if cursor:
                    body["cursor"] = cursor
                page = self._call("POST", "/v2/calls/transcript", body)
                for t in page.get("callTranscripts", []):
                    out[t["callId"]] = t.get("transcript", [])
                cursor = page.get("records", {}).get("cursor")
                if not cursor:
                    break
            time.sleep(0.4)
        return out


def fold_utterances(utts: list[dict]) -> list[dict]:
    """Timed (side, start, end, text) utterances → Me/Them lines, merging
    same-side runs separated by < 4s. Mirrors how Cue's STT commits lines."""
    lines: list[dict] = []
    for u in sorted(utts, key=lambda u: u["start"]):
        text = (u.get("text") or "").strip()
        if not text:
            continue
        if lines and lines[-1]["speaker"] == u["side"] and u["start"] - lines[-1]["end"] < 4000:
            lines[-1]["text"] += " " + text
            lines[-1]["end"] = u["end"]
        else:
            lines.append({"speaker": u["side"], "text": text, "start": u["start"], "end": u["end"]})
    return [{"speaker": l["speaker"], "text": l["text"]} for l in lines]


def fold_gong_dialogue(monologues: list[dict], parties: list[dict]) -> list[dict]:
    side_by_speaker = {}
    for p in parties:
        if p.get("speakerId"):
            side_by_speaker[p["speakerId"]] = "Me" if p.get("affiliation") == "Internal" else "Them"
    utts = [
        {"side": side_by_speaker.get(m.get("speakerId"), "Them"),
         "start": s.get("start", 0), "end": s.get("end", 0), "text": s.get("text", "")}
        for m in monologues for s in m.get("sentences", [])
    ]
    return fold_utterances(utts)


def databricks_query(sql: str, profile: str, params: dict[str, str] | None = None) -> list[dict]:
    cmd = ["databricks", "experimental", "aitools", "tools", "query", sql, "--profile", profile]
    for k, v in (params or {}).items():
        cmd += ["--param", f"{k}={v}"]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        raise SystemExit(f"databricks query failed:\n{proc.stderr.strip() or proc.stdout.strip()}")
    return json.loads(proc.stdout)


def load_databricks(args: argparse.Namespace) -> list[dict]:
    """Pick recent calls with real two-sided dialogue, then pull utterances
    joined to speaker affiliation. One query per call keeps results small."""
    t = args.table_prefix
    since = (datetime.now(timezone.utc) - timedelta(days=args.days)).strftime("%Y-%m-%d")
    selection = f"""
    WITH sides AS (
      SELECT u.call_id,
             SUM(CASE WHEN s.affiliation_norm = 'external' THEN 1 ELSE 0 END) AS ext_utts,
             SUM(CASE WHEN s.affiliation_norm = 'internal' THEN 1 ELSE 0 END) AS int_utts
      FROM {t}.utterances u
      JOIN {t}.calls c ON c.call_id = u.call_id
      JOIN {t}.speaker_map s ON s.call_id = u.call_id AND s.speaker_id = u.speaker_id
      WHERE c.started >= :since
      GROUP BY u.call_id)
    SELECT c.call_id, c.title, c.started, c.url
    FROM {t}.calls c JOIN sides ON sides.call_id = c.call_id
    WHERE sides.ext_utts >= 40 AND sides.int_utts >= 40
      AND c.duration_sec BETWEEN 900 AND 4000
      {"AND lower(c.title) LIKE :needle" if args.title_filter else ""}
    ORDER BY c.started DESC LIMIT {int(args.max_calls)}
    """
    params = {"since": since}
    if args.title_filter:
        params["needle"] = f"%{args.title_filter.lower()}%"
    if args.call_id:
        ids = ",".join(f"'{cid}'" for cid in args.call_id)
        selection = f"SELECT call_id, title, started, url FROM {t}.calls WHERE call_id IN ({ids}) ORDER BY started DESC"
        params = {}
    calls = databricks_query(selection, args.profile, params)
    print(f"{len(calls)} calls selected from {t}" + ("" if args.call_id else f" since {since}"), flush=True)

    utterance_sql = f"""
    SELECT u.start_ms, u.end_ms, u.text,
           CASE WHEN s.affiliation_norm = 'internal' THEN 'Me' ELSE 'Them' END AS side
    FROM {t}.utterances u
    JOIN {t}.speaker_map s ON s.call_id = u.call_id AND s.speaker_id = u.speaker_id
    WHERE u.call_id = :call_id
    ORDER BY u.start_ms
    """
    out: list[dict] = []
    for c in calls:
        rows = databricks_query(utterance_sql, args.profile, {"call_id": c["call_id"]})
        utts = [{"side": r["side"], "start": int(r["start_ms"]), "end": int(r["end_ms"]), "text": r["text"]} for r in rows]
        out.append({
            "id": c["call_id"],
            "title": c["title"],
            "started": c["started"],
            "url": c["url"],
            "lines": fold_utterances(utts),
        })
    return out


def load_gong(args: argparse.Namespace) -> list[dict]:
    """Fetch from Gong REST and normalise to the --from-json call shape."""
    gong = Gong()
    calls = gong.list_calls(args.days, args.max_calls * 3 if args.title_filter else args.max_calls)
    if args.title_filter:
        needle = args.title_filter.lower()
        calls = [c for c in calls if needle in (c.get("title") or "").lower()][: args.max_calls]
    if not calls:
        return []
    ids = [c["id"] for c in calls]
    print(f"{len(calls)} Gong calls; fetching parties + transcripts…", flush=True)
    parties = gong.parties(ids)
    transcripts = gong.transcripts(ids)
    return [{
        "id": c["id"],
        "title": c.get("title"),
        "started": c.get("started"),
        "url": c.get("url"),
        "lines": fold_gong_dialogue(transcripts.get(c["id"], []), parties.get(c["id"], [])),
    } for c in calls]


def load_json(path: Path) -> list[dict]:
    data = json.loads(path.read_text(encoding="utf-8"))
    calls = data["calls"] if isinstance(data, dict) else data
    for c in calls:
        for l in c.get("lines", []):
            if l.get("speaker") not in ("Me", "Them"):
                raise SystemExit(f"{path}: call {c.get('id')} has speaker {l.get('speaker')!r}; expected Me|Them")
    return calls


def chunk_lines(lines: list[dict]) -> list[tuple[int, list[dict]]]:
    chunks: list[tuple[int, list[dict]]] = []
    start = 0
    while start < len(lines):
        words = 0
        end = start
        while end < len(lines) and words < CHUNK_WORDS:
            words += len(lines[end]["text"].split())
            end += 1
        chunks.append((start, lines[start:end]))
        if end >= len(lines):
            break
        start = max(end - CHUNK_OVERLAP_LINES, start + 1)
    return chunks


EXTRACT_SYSTEM = """You are building an evaluation set for a live call copilot used by solutions \
architects and account execs. "Me" is the vendor side (SA or AE); "Them" is the customer. Each transcript \
line is prefixed with its index like [17].

Find every question from Them that Me was expected to answer: product, capability, pricing, process, \
security, timeline, integration, "can you / do you / how does it". Skip call logistics, banter, \
rhetorical questions, and questions Me asked.

Tag each with a category:
- technical: how it works, does it support X, architecture, auth/SSO/SCIM, networking, data handling, \
  APIs/SDK, deployment, limits, integrations, security/compliance mechanics
- commercial: pricing, seats, tiers, contracts, discounts, procurement
- process: enablement, timelines, support, next steps, logistics that still need a real answer
- other

Return only valid JSON:
{"questions": [{
  "line": 17,
  "raw": "the customer's words, lightly cleaned",
  "question": "self-contained restatement with pronouns resolved",
  "category": "technical|commercial|process|other",
  "status": "answered|deferred|ignored",
  "rep_answer": "what Me actually said in reply, condensed but faithful; empty if none",
  "answer_quality": "strong|adequate|weak"
}]}

- line is the index of the Them line that completes the question.
- status: answered = Me gave substance; deferred = Me promised to follow up; ignored = no reply.
- answer_quality judges Me's reply on its own terms (specific, correct-sounding, spoken well).
- Do not invent. Empty list is fine."""


def _xai_chat(payload: dict, key: str) -> str | None:
    """Chat completion with backoff on 429/5xx. None after exhausting retries."""
    req = urllib.request.Request(API_URL, data=json.dumps(payload).encode(), headers={
        "Authorization": f"Bearer {key}", "Content-Type": "application/json",
    })
    for attempt in range(6):
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                return json.load(r)["choices"][0]["message"]["content"].strip()
        except urllib.error.HTTPError as e:
            if e.code == 429 or e.code >= 500:
                wait = 5 * 2 ** attempt
                print(f"  ! xAI {e.code}; retrying in {wait}s", file=sys.stderr, flush=True)
                time.sleep(wait)
                continue
            raise
    print("  ! xAI: giving up on this chunk", file=sys.stderr, flush=True)
    return None


def extract_questions(lines: list[dict], key: str) -> list[dict]:
    found: dict[int, dict] = {}
    for offset, chunk in chunk_lines(lines):
        numbered = "\n".join(f"[{offset + i}] {l['speaker']}: {l['text']}" for i, l in enumerate(chunk))
        payload = {
            "model": MODEL,
            "temperature": 0.1,
            "max_tokens": 2500,
            "reasoning_effort": "low",
            "messages": [
                {"role": "system", "content": EXTRACT_SYSTEM},
                {"role": "user", "content": f"TRANSCRIPT:\n{numbered}"},
            ],
        }
        content = _xai_chat(payload, key)
        if content is None:
            continue
        if content.startswith("```"):
            content = content.strip("`").removeprefix("json").strip()
        try:
            items = json.loads(content).get("questions", [])
        except json.JSONDecodeError:
            print("  ! unparseable extraction chunk", file=sys.stderr)
            continue
        for q in items:
            line = q.get("line")
            if isinstance(line, int) and 0 <= line < len(lines) and q.get("question"):
                found.setdefault(line, q)  # overlap: first sighting wins
    return [found[k] for k in sorted(found)]


def window_before(lines: list[dict], line_index: int) -> str:
    """Dialogue Cue would have had in recentWindow when this line landed."""
    text = "\n".join(f"{l['speaker']}: {l['text']}" for l in lines[: line_index + 1])
    return " ".join(text.split(" ")[-WINDOW_WORDS:])


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--databricks", action="store_true", help="fetch from Unity Catalog via the Databricks CLI")
    src.add_argument("--from-json", type=Path, help="transcripts JSON (see module doc for shape)")
    src.add_argument("--gong", action="store_true", help="fetch from Gong REST API")
    ap.add_argument("--profile", help="[--databricks] CLI profile (required; never auto-selected)")
    ap.add_argument("--table-prefix", default="dev.rperry", help="[--databricks] catalog.schema holding calls/utterances/speaker_map")
    ap.add_argument("--days", type=int, default=30, help="[--databricks/--gong] look back this many days")
    ap.add_argument("--max-calls", type=int, default=20, help="[--databricks/--gong] cap on calls")
    ap.add_argument("--title-filter", default="", help="[--databricks/--gong] only titles containing this")
    ap.add_argument("--call-id", nargs="*", default=[], help="[--databricks] mine exactly these calls (ignores --days/--title-filter)")
    ap.add_argument("--technical", action="store_true", help="keep only category=technical questions")
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    args = ap.parse_args()
    if args.databricks and not args.profile:
        ap.error("--databricks requires --profile (run `databricks auth profiles` to list them)")

    key = api_key()
    if not key:
        print("Missing XAI_API_KEY", file=sys.stderr)
        return 1
    _load_dotenv()

    if args.databricks:
        calls = load_databricks(args)
    elif args.gong:
        calls = load_gong(args)
    else:
        calls = load_json(args.from_json)
    if not calls:
        print("No calls to mine", file=sys.stderr)
        return 1

    args.out.parent.mkdir(parents=True, exist_ok=True)
    records: list[dict] = []
    done_calls = 0

    def flush() -> None:
        args.out.write_text(json.dumps({
            "generated": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "calls": done_calls,
            "questions": len(records),
            "records": records,
        }, indent=2) + "\n", encoding="utf-8")

    for c in calls:
        cid = c.get("id", "")
        lines = c.get("lines", [])
        if len(lines) < 10:
            continue
        print(f"\n== {(c.get('started') or '')[:10]}  {c.get('title', '')}  ({len(lines)} lines)", flush=True)
        questions = extract_questions(lines, key)
        for q in questions:
            category = q.get("category", "other")
            if args.technical and category != "technical":
                continue
            records.append({
                "call_id": cid,
                "call_title": c.get("title"),
                "call_started": c.get("started"),
                "call_url": c.get("url"),
                "line": q["line"],
                "raw": q.get("raw", ""),
                "question": q["question"],
                "category": category,
                "status": q.get("status", ""),
                "rep_answer": q.get("rep_answer", ""),
                "answer_quality": q.get("answer_quality", ""),
                "window_before": window_before(lines, q["line"]),
                "meeting_type": "technical" if category == "technical" else "sales",
            })
            print(f"  [{q.get('status', '?'):8}] {q['question']}", flush=True)
        done_calls += 1
        flush()  # partial results survive a crash or Ctrl-C
        time.sleep(1.0)

    by_status: dict[str, int] = {}
    for r in records:
        by_status[r["status"]] = by_status.get(r["status"], 0) + 1
    print(f"\n{len(records)} questions from {done_calls} calls  {by_status}\nwrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
