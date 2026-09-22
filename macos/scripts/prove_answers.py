#!/usr/bin/env python3
"""Headless Cue answer-proof harness (Design A).

Run:
  python3 macos/scripts/prove_answers.py [--session call-....md] [--limit 8] \\
      [--min-answered 3] [--notes ""] [--meeting-type technical|sales|interview|internal] \\
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

from repro_source_search import (  # noqa: E402
    MAX_DF,
    basename_keyword_boost,
    keywords,
    path_boost,
    rg,
)

SESSIONS_DIR = Path.home() / "Library/Application Support/Cue/sessions"
KNOWLEDGE_DIR = Path.home() / "Library/Application Support/Cue/knowledge"
PREP_DIR = Path.home() / "Library/Application Support/Cue/prep"
OUT_JSON = Path("/tmp/cue-prove-answers.json")
MODEL = "grok-4.6"
API_URL = "https://api.x.ai/v1/chat/completions"
LINE_RE = re.compile(r"^- \*\*(.+?)\*\* \(([^)]+)\):\s*(.*)$")

WINDOW_WORDS = {
    "technical": 600,
    "sales": 400,
    "interview": 1200,
    "internalSync": 600,
}
TRANSCRIPT_CHARS = {
    "technical": 5000,
    "sales": 3500,
    "interview": 12000,
    "internalSync": 6000,
}

# Mirrors MeetingType.snippetCharBudget.
SNIPPET_CHARS = {
    "technical": 11000,
    "interview": 9000,
}

MEETING_ALIASES = {
    "technical": "technical",
    "sales": "sales",
    "interview": "interview",
    "internal": "internalSync",
    "internalsync": "internalSync",
}

# Heuristic question picker for mining probe questions out of saved sessions.
# The app itself no longer uses this; ConversationAnalyst (LLM) decides live.
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
    if meeting_type == "technical":
        # Mirrors MeetingType.quickSystemPrompt(.technical); keep in sync.
        who = ("The user typed a question for help." if user_asked
               else "Someone on the call just asked a technical question.")
        skip = ("- Always answer. Never reply SKIP." if user_asked
                else "- Only reply SKIP if this is clearly not a question (banter, filler, the user talking to themselves).")
        return (
            "You are a live copilot for a solutions architect on a technical call (architecture, security, "
            f"integration, deployment, API/SDK). {who} Give a spoken-ready answer for the next 5 seconds.\n\n"
            "Rules:\n"
            "- 2 to 4 short sentences. No preamble. Precise over polished: name the mechanism, the setting, "
            "the limit, the port — whatever the question actually turns on.\n"
            "- Shape: sentence one is the direct answer (yes / no / partly / \"today X, not Y\"). Then how it "
            "works. At most ONE hedge in the whole answer — never stack \"generally\", \"typically\", "
            "\"internally\", \"not committed\" across sentences.\n"
            "- Prefer facts from PREP and NOTES, then what was already said in the RECENT TRANSCRIPT.\n"
            "- If the transcript already answered it (even partially), state that fact; do not stall.\n"
            "- Do not invent limits, defaults, version numbers, or security claims that are not in prep/notes/transcript. "
            "If you are working from general knowledge, say so in two words (\"generally,\" \"by default,\") and keep it short.\n"
            "- Distinguish what ships today from what is internal or roadmap; never present internal as shipped.\n"
            "- Sources in order: transcript, PREP, NOTES, then general engineering and public product knowledge "
            "(marked \"generally\"). A deferral is the last resort, only for facts nobody on our side could know "
            "right now (their contract, an unpublished number) — and even then say what IS known first and name "
            "the one thing to confirm. Never a bare \"I'll get back to you\".\n"
            f"{skip}\n"
        )
    if meeting_type == "interview":
        if user_asked:
            return (
                "You are a live interviewer copilot. The interviewer typed a request during a hiring interview.\n"
                "Write for the interviewer: eval signal, synthesis, gaps, or a sharp follow-up — not a customer pitch.\n\n"
                "Rules:\n"
                "- 3 to 6 short sentences or bullets. No preamble, no hedging filler.\n"
                "- Prefer concrete evidence from RECENT TRANSCRIPT (names, metrics, claims, architecture choices).\n"
                "- Quote or paraphrase specific candidate claims when summarizing; do not invent them.\n"
                "- If suggesting a question to ask the candidate, prefix with \"Ask:\".\n"
                "- Never reply SKIP. Never say you lack context if the transcript has relevant substance.\n"
                "- Avoid deferrals like \"I'd need more info\" when the transcript already covers the topic.\n"
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
            "- Deferrals are a last resort: say what IS known from any source first, then name the one "
            "thing to confirm. Never a bare \"I'll get back to you\".\n"
        )
    return (
        "You are a live sales/customer-call copilot sitting next to the user.\n"
        "A customer just asked a question. Give the user a spoken-ready answer they can say in the next 5 seconds.\n\n"
        "Rules:\n"
        "- 2 to 4 short sentences. No preamble.\n"
        "- Prefer facts from NOTES, then from what was already said in the RECENT TRANSCRIPT "
        "(setup steps, decisions, names, what the user already committed to on this call).\n"
        "- If the transcript already answered the question (even partially), say that fact — "
        "do not stall with \"let me confirm\" / \"I don't want to guess.\"\n"
        "- Do not invent prices, SLAs, legal commitments, or product claims that are not in notes/transcript.\n"
        "- For process/UI/setup questions, a clear next step from the conversation is useful — give it.\n"
        "- Only reply SKIP if this is clearly not a customer question (banter, the user talking to themselves, "
        "or pure filler with no ask).\n"
        "- Deferrals are a last resort: say what IS known from any source first, then name the one "
        "thing to confirm. Not SKIP.\n"
    )


def sourced_system(meeting_type: str, user_asked: bool, has_draft: bool = False) -> str:
    if meeting_type == "technical":
        # Mirrors MeetingType.sourcedSystemPrompt(.technical); keep in sync.
        skip = (
            "- A CURRENT DRAFT ANSWER is provided. Return the single best spoken answer: keep what "
            "is right in the draft, correct it with facts from snippets, and make it more specific — "
            "never vaguer. Never reply SKIP. Do not replace a substantive draft with a deferral."
            if has_draft
            else "- Always answer. Sources in order: snippets, prep, notes, transcript, then general "
            "engineering and public product knowledge marked \"generally\". Never reply SKIP. Defer "
            "only on facts nobody on our side could know right now, and even then state what IS "
            "known first and name the one thing to confirm."
        )
        who = "The user asked a question" if user_asked else "Someone on the call asked a technical question"
        return (
            f"You are a live copilot for a solutions architect on a technical call. {who} "
            "and internal docs, code, and playbook snippets that may answer it are provided. "
            "Give the user a spoken-ready, technically precise answer.\n\n"
            "Rules:\n"
            "- 2 to 5 short sentences the user can say out loud. Sentence one is the direct answer "
            "(yes / no / partly / \"today X, not Y\"), then the mechanism or concrete value (setting name, "
            "limit, port, protocol, flow), then at most ONE caveat. Never stack hedges — pick the one "
            "that matters and drop the rest. Plain words over product jargon.\n"
            "- Trust order for PRODUCT BEHAVIOUR when sources disagree: what was said on THIS call > "
            "product-docs/ (public docs, what we commit to externally) > grok-bot-internal/ (internal FAQ "
            "and decks: accurate, but internal-only — state the fact in your own words, never as something "
            "the customer can read) > internal-docs/ and code > playbook/ entries (dated) > NOTES. For THIS "
            "CUSTOMER's history, promises, and constraints, PREP DOCS FOR THIS CALL win.\n"
            "- Code and internal docs describe how it is built, not always what is shipped or supported. "
            "When a snippet is an internal spec, a route list, a feature flag, or a test, say the fact "
            "but mark it: \"internally\" / \"not something I would commit to yet\" — never present it as GA.\n"
            "- Playbook entries may list PITFALLS — things Cue has said before that were wrong. Never repeat one.\n"
            "- Only use a snippet if it clearly addresses this question. Do not stretch an adjacent doc into an answer.\n"
            "- Do not invent product-specific limits, defaults, versions, SLAs, or compliance claims absent from "
            "snippets/prep/notes/transcript. General engineering facts (how SAML, SCIM, VPC peering, OAuth, "
            "key rotation work) and public product behaviour are fair game — mark them \"generally\" / \"by default\".\n"
            "- When a claim comes from a file, cite it in parentheses with the path, e.g. (internal-docs/foo.md).\n"
            "- If snippets are irrelevant but the transcript already answered it, say that briefly.\n"
            f"{skip}\n"
        )
    if meeting_type == "interview":
        skip = (
            "- Always answer. Never reply SKIP. Never defer if transcript/snippets have substance."
            if user_asked
            else "- Only reply SKIP if nothing helps the interviewer."
        )
        return (
            "You are a live interviewer copilot. Snippets may include live-dialogue / session transcript "
            "and docs. Write for the interviewer (signal, synthesis, gaps, follow-ups) — not a pitch.\n\n"
            "Rules:\n"
            "- 3 to 6 short sentences or bullets with concrete evidence.\n"
            "- Prefer live-dialogue / call-* snippets and NOTES over unrelated repo docs.\n"
            "- Cite files in parentheses when used (e.g. live-dialogue, call-….md).\n"
            "- Do not invent candidate or product claims.\n"
            "- Prefix suggested candidate questions with \"Ask:\".\n"
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
        "- A CURRENT DRAFT ANSWER is provided. Return the single best spoken answer: keep what "
        "is right in the draft, add or correct it with facts from snippets, notes, or the "
        "transcript, and make it more specific — never vaguer. Never reply SKIP. Do not replace a "
        "substantive draft with a deferral."
        if has_draft
        else "- Always answer from snippets, notes, or transcript. Never reply SKIP. If none of them "
        "settle it, say what IS known first and name the one thing to confirm — never a bare deferral."
    )
    who = "The user asked a question" if user_asked else "The customer asked a question"
    return (
        f"You are a live call copilot. {who} and internal docs/snippets that may answer it "
        "are provided. Give the user a spoken-ready answer.\n\n"
        # Mirrors MeetingType.sourcedSystemPrompt(.sales); keep in sync.
        "Rules:\n"
        "- 2 to 5 short sentences the user can say out loud.\n"
        "- Trust order when sources disagree: what was said on THIS call > PREP DOCS FOR THIS CALL "
        "> product-docs/ (public docs) > grok-bot-internal/ (internal FAQ; state facts, never as customer-readable) "
        "> playbook/ entries (how reps actually answer, dated) > NOTES > other docs.\n"
        "- Playbook entries may list PITFALLS — things Cue has said before that were wrong. "
        "Never repeat a pitfall. If an entry says \"as of\" a date, you may say \"as of <month>\".\n"
        "- Only use a snippet if it clearly addresses this question. Do not stretch a doc that "
        "is about something adjacent (an internal spec, a route list, a telemetry README) into "
        "a product answer — that produces confident wrong answers.\n"
        "- Do not invent prices, SLAs, or product claims absent from snippets/notes/transcript.\n"
        "- When a claim comes from a file, cite it in parentheses, e.g. (playbook/foo.md).\n"
        "- If snippets are irrelevant but the transcript already answered it, say that briefly.\n"
        f"{skip}\n"
    )


def ask_label(meeting_type: str) -> str:
    if meeting_type == "technical":
        return "TECHNICAL ASK"
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


def _load_dotenv() -> None:
    """Best-effort load of repo-root / macos `.env` into os.environ (no overwrite)."""
    here = Path(__file__).resolve()
    candidates = [
        here.parents[2] / ".env",  # repo root (…/livetranscription/.env)
        here.parents[1] / ".env",  # macos/.env
        Path.cwd() / ".env",
    ]
    seen: set[Path] = set()
    for path in candidates:
        try:
            path = path.resolve()
        except OSError:
            continue
        if path in seen or not path.is_file():
            continue
        seen.add(path)
        for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[len("export ") :].strip()
            if "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip().strip("'").strip('"')
            if key and key not in os.environ:
                os.environ[key] = value


def api_key() -> str | None:
    _load_dotenv()
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


def window_from(preceding: list[TranscriptLine], meeting_type: str = "sales") -> str:
    budget = WINDOW_WORDS.get(meeting_type, 400)
    words: list[str] = []
    for line in preceding:
        words.extend(line.dialogue().split())
    return " ".join(words[-budget:])


def extract_probes(session_path: Path, meeting_type: str = "sales") -> list[Probe]:
    lines = parse_session(session_path)
    probes: list[Probe] = []
    seen: set[str] = set()
    budget = WINDOW_WORDS.get(meeting_type, 400)
    rolling = ""
    for i, line in enumerate(lines):
        rolling = (rolling + "\n" + line.dialogue()).strip()
        rolling = " ".join(rolling.split()[-budget:])
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
                window=window_from(lines[:i], meeting_type),
            )
        )
    return probes


def session_window(session_path: Path, meeting_type: str = "sales") -> str:
    lines = parse_session(session_path)
    return window_from(lines, meeting_type)


def dialogue_snippets(question: str, dialogue: str, label: str = "live-dialogue") -> list[dict[str, str]]:
    trimmed = dialogue.strip()
    if len(trimmed) < 40:
        return []
    kws = keywords(question, limit=6)
    scored: list[tuple[int, str]] = []
    for line in trimmed.splitlines():
        lower = line.lower()
        score = sum(1 for k in kws if k in lower)
        if score > 0:
            scored.append((score, line))
    scored.sort(key=lambda x: -x[0])
    if scored:
        body = "\n".join(line for _, line in scored[:8])[:2000]
        return [{"file": label, "snippet": body}]
    return [{"file": label, "snippet": trimmed[-2000:]}]


def transcript_file_snippets(question: str, session_path: Path) -> list[dict[str, str]]:
    if not session_path.is_file():
        return []
    text = session_path.read_text(encoding="utf-8", errors="replace")
    kws = keywords(question, limit=8)
    if not kws:
        return [{"file": session_path.name, "snippet": text[-2200:]}]
    scored: list[tuple[int, str]] = []
    for line in text.splitlines():
        lower = line.lower()
        score = sum(1 for k in kws if k in lower)
        if score > 0 and len(line) > 20:
            scored.append((score, line))
    scored.sort(key=lambda x: -x[0])
    if scored:
        body = "\n".join(line for _, line in scored[:12])[:2200]
        return [{"file": session_path.name, "snippet": body}]
    return [{"file": session_path.name, "snippet": text[-2200:]}]


def merge_hits(*groups: list[dict[str, str]], limit: int = 6) -> list[dict[str, str]]:
    out: list[dict[str, str]] = []
    seen: set[str] = set()
    for group in groups:
        for hit in group:
            key = hit["file"]
            if key in seen:
                continue
            seen.add(key)
            out.append(hit)
            if len(out) >= limit:
                return out
    return out


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
        args = [
            "-il",
            "--type",
            "md",
            "--max-filesize",
            "400K",
            "--glob",
            "!**/__snapshots__/**",
            "--glob",
            "!**/node_modules/**",
            "--glob",
            "!**/.git/**",
            "--glob",
            "!**/i18n/**",
            "--glob",
            "!**/i18n-*/**",
            "--glob",
            "!**/changelog/**",
            "--glob",
            "!**/*.generated.md",
            rf"\b{escaped}",
            *roots,
        ]
        out = rg(args)
        return [
            line
            for line in out.splitlines()
            if line
            and Path(line).name not in exclude
            and "__snapshots__" not in line.lower()
            and "/i18n/" not in line.lower()
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
    matched: dict[str, int] = {}
    kept_kws = [k for k, _ in keyword_files]
    for _, files in keyword_files:
        weight = 1.0 / len(files)
        for path in files:
            matched[path] = matched.get(path, 0) + 1
            scores[path] = (
                scores.get(path, 0.0)
                + weight
                + path_boost(path)
                + basename_keyword_boost(path, kept_kws)
            )
    # Mirrors SourceSearch: one shared word is not evidence in a small corpus.
    if len(kept_kws) >= 2:
        scores = {p: s for p, s in scores.items() if matched[p] >= 2}

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


# Mirrors AnswerEngine.answerSchema.
ANSWER_SCHEMA = {
    "type": "json_schema",
    "json_schema": {
        "name": "spoken_answer",
        "strict": True,
        "schema": {
            "type": "object",
            "properties": {
                "answer": {"type": "string",
                           "description": "The spoken-ready answer text exactly as the user should read it, or SKIP."},
                "sources": {"type": "array", "items": {"type": "string"},
                            "description": "FILE paths of the snippets this answer actually relies on, verbatim as given. "
                                           "Empty when the answer came from the transcript, prep, notes, or general knowledge."},
            },
            "required": ["answer", "sources"],
            "additionalProperties": False,
        },
    },
}


def chat(system: str, user: str, max_tokens: int, key: str) -> str:
    payload = {
        "model": MODEL,
        "temperature": 0.2,
        "max_tokens": max_tokens,
        "reasoning_effort": "low",
        "response_format": ANSWER_SCHEMA,
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
    with urllib.request.urlopen(req, timeout=35) as resp:
        body = json.loads(resp.read().decode("utf-8"))
    content = (
        body.get("choices", [{}])[0]
        .get("message", {})
        .get("content", "")
    )
    if isinstance(content, str):
        try:
            content = json.loads(content.strip().strip("`").removeprefix("json")).get("answer", content)
        except (json.JSONDecodeError, AttributeError):
            pass
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
    budget = TRANSCRIPT_CHARS.get(meeting_type, 3500)
    max_tokens = 280 if meeting_type == "interview" and user_asked else 180
    user = (
        f"CONTEXT / NOTES:\n"
        f"{notes if notes else '(none provided)'}\n\n"
        f"RECENT TRANSCRIPT:\n"
        f"{window[-budget:]}\n\n"
        f"{label}:\n"
        f"{question}"
    )
    return chat(quick_system(meeting_type, user_asked), user, max_tokens, key)


def sourced_answer(
    question: str,
    snippets: str,
    notes: str,
    window: str,
    key: str,
    *,
    meeting_type: str,
    user_asked: bool,
    draft: str = "",
) -> str:
    notes_bit = notes[:1200] if notes else "(none)"
    label = ask_label(meeting_type)
    budget = min(TRANSCRIPT_CHARS.get(meeting_type, 3500), 4000)
    snippet_budget = SNIPPET_CHARS.get(meeting_type, 7000)
    max_tokens = 480  # mirrors AnswerEngine.sourcedAnswer
    user = (
        f"{label}:\n"
        f"{question}\n\n"
        f"RECENT CONVERSATION (for what the question refers to):\n"
        f"{window[-budget:]}\n\n"
        f"USER'S NOTES:\n"
        f"{notes_bit}\n\n"
        f"REPO/DOCS SNIPPETS:\n"
        f"{snippets[:snippet_budget]}"
        + (f"\n\nCURRENT DRAFT ANSWER (from the quick pass):\n{draft}" if draft else "")
    )
    return chat(sourced_system(meeting_type, user_asked, bool(draft)), user, max_tokens, key)


def classify(quick: str, sourced: str, *, failed: bool) -> str:
    if failed:
        return "failed"
    if quick:
        return "answered"
    if sourced:
        return "sourced_only"
    return "skipped"


DEFERRAL_MARKERS = (
    "don't have that",
    "do not have that",
    "i'd need more",
    "need more info",
    "not in the notes",
    "not in notes",
    "no matching",
    "can't find",
    "cannot find",
    "looking up",
    "i don't know",
    "i do not know",
    "outside my",
    "not sure from",
    "don't want to guess",
    "do not want to guess",
    "let me confirm",
    "let me check",
    "i'll check and get back",
)


def quality_flags(text: str) -> list[str]:
    flags: list[str] = []
    t = text.strip()
    if not t:
        flags.append("empty")
        return flags
    lower = t.lower()
    if any(m in lower for m in DEFERRAL_MARKERS):
        flags.append("deferral")
    if len(t) < 40:
        flags.append("too_short")
    # concrete signal: numbers, proper-ish words, or Ask:
    if "ask:" in lower:
        flags.append("has_followup")
    if re.search(r"\b\d+\b", t):
        flags.append("has_number")
    return flags


def knowledge_roots() -> list[str]:
    roots: list[str] = []
    # CUE_SKIP_KNOWLEDGE=1 replays a no-playbook baseline for A/B runs.
    if not os.environ.get("CUE_SKIP_KNOWLEDGE"):
        for d in (PREP_DIR, KNOWLEDGE_DIR):
            if d.exists():
                roots.append(str(d))
    if root := os.environ.get("CUE_SOURCE_ROOT", "").strip():
        roots.append(str(Path(root).expanduser()))
        expanded = str(Path(root).expanduser())
        if "everysphere" in expanded.lower():
            portal = Path(expanded) / "internal-docs"
            if portal.exists():
                roots.append(str(portal))
    if SESSIONS_DIR.exists():
        roots.append(str(SESSIONS_DIR))
    # de-dupe preserving order
    seen: set[str] = set()
    out: list[str] = []
    for r in roots:
        if r not in seen:
            seen.add(r)
            out.append(r)
    return out


def run_probe(
    probe: Probe,
    notes: str,
    roots: list[str],
    key: str,
    meeting_type: str,
) -> ProbeResult:
    result = ProbeResult(probe=probe)
    user_asked = probe.user_asked
    prefer_transcript = meeting_type == "interview"
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

    session_path = SESSIONS_DIR / probe.session
    local_hits = merge_hits(
        dialogue_snippets(probe.question, probe.window),
    )
    if prefer_transcript or user_asked:
        local_hits = merge_hits(
            local_hits,
            transcript_file_snippets(probe.question, session_path),
        )
    exclude = set() if prefer_transcript else {probe.session}
    repo_hits = search_hits(
        probe.question, roots, exclude=exclude, context=probe.window
    )
    hits = merge_hits(local_hits, repo_hits, limit=6)
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
            "Missing XAI_API_KEY (.env, env, or keychain com.davidgeorgehope.cue / xai).",
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
                window=session_window(path, meeting_type),
                user_asked=True,
            )
        ]
    else:
        for path in files:
            probes.extend(extract_probes(path, meeting_type))
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
    great_n = 0
    for r in results:
        best = r.sourced or r.quick
        flags = quality_flags(best)
        if best and "empty" not in flags and "deferral" not in flags and "too_short" not in flags:
            great_n += 1

    print("-" * 96, flush=True)
    by = {v: 0 for v in ("answered", "sourced_only", "skipped", "failed")}
    for r in results:
        by[r.verdict] = by.get(r.verdict, 0) + 1
    print(
        f"probes={len(results)} non_empty={answered_n} great={great_n} "
        f"answered={by['answered']} sourced_only={by['sourced_only']} "
        f"skipped={by['skipped']} failed={by['failed']} "
        f"min_answered={min_answered}"
    )

    payload = {
        "meeting_type": meeting_type,
        "user_asked": bool(ask_text),
        "min_answered": min_answered,
        "non_empty": answered_n,
        "great": great_n,
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
                "quality_flags": quality_flags(r.sourced or r.quick),
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
