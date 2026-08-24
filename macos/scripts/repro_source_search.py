#!/usr/bin/env python3
"""Rerun Cue's SourceSearch logic against real call questions.

Mirrors macos/Sources/Cue/Intelligence/SourceSearch.swift so a reviewer
can reproduce miss/hit behavior without launching the app.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

RG = "/opt/homebrew/bin/rg"
MAX_DF = 800
STOPWORDS = {
    "the", "and", "for", "are", "you", "your", "our", "can", "could", "would",
    "will", "does", "did", "how", "what", "when", "where", "who", "why", "which",
    "that", "this", "these", "those", "with", "have", "has", "had", "was", "were",
    "there", "their", "they", "them", "then", "than", "but", "not", "all", "any",
    "get", "got", "just", "like", "yeah", "okay", "about", "into", "over", "some",
    "much", "many", "very", "really", "kind", "sort", "know", "think", "want",
    "need", "going", "gonna", "say", "said", "curious", "specific", "actually",
    "wanted", "also", "look", "looking", "looks", "options", "option", "flexible",
    "right", "sure", "little", "bit", "lot", "mean", "means", "guys", "folks",
    "basically", "come", "comes", "thing", "things", "stuff", "way", "ways",
    "make", "makes", "made", "use", "using", "used", "see", "seen", "still",
    "now", "well", "good", "great", "back", "out", "one", "two", "let", "lets",
    "here", "been", "being", "its", "his", "her", "him", "she", "from",
}

DEFAULT_QUESTIONS = [
    "Is that something which is integrated natively in this overview, the overview that you have?",
    "can a viewer interact with these changes, I mean, asking questions to get insights is that a capability available here?",
    "is this also for the GitHub Enterprise server? Like, can we do that same work from an Enterprise server?",
    "is there a native migration that we support for moving from the GitHub Actions CI jobs to Origin?",
    "So Matthew, so how do we enable this for the subset of users?",
    "So it'll be part of same cursor or is there a different endpoint for this?",
    "Do we get a support during the POC?",
    "but we wanted to be flexible and also look at options for automerge?",
    "So how, how does it look like in Origin?",
]


def keywords(text: str, limit: int = 8) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for word in re.split(r"[^a-z0-9]+", text.lower()):
        if len(word) < 3 or word in STOPWORDS or word in seen:
            continue
        seen.add(word)
        out.append(word)
        if len(out) == limit:
            break
    return out


def rg(args: list[str], timeout: float = 4.0) -> str:
    try:
        proc = subprocess.run(
            [RG, *args],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        return proc.stdout
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return ""


def path_boost(path: str) -> float:
    lower = path.lower()
    boost = 0.0
    if "/docs/" in lower:
        boost += 0.05
    if "origin" in lower:
        boost += 0.08
    if "scm-integrations" in lower:
        boost += 0.06
    if Path(path).name.startswith("call-"):
        boost -= 0.2
    return boost


def search(question: str, roots: list[str], exclude: set[str] | None = None) -> dict:
    exclude = exclude or set()
    candidates = keywords(question)

    def files_for(keyword: str) -> list[str]:
        escaped = re.escape(keyword)
        out = rg(["-il", "--type", "md", "--max-filesize", "300K", rf"\b{escaped}", *roots])
        return [
            line
            for line in out.splitlines()
            if line and Path(line).name not in exclude
        ]

    keyword_files: list[tuple[str, list[str]]] = []
    dropped: list[tuple[str, str]] = []
    for keyword in candidates:
        files = files_for(keyword)
        if not files:
            dropped.append((keyword, "0 hits"))
            continue
        if len(files) > MAX_DF and len(candidates) > 1:
            dropped.append((keyword, f"df={len(files)}>max"))
            continue
        if len(files) > 2500:
            dropped.append((keyword, f"df={len(files)}>hard"))
            continue
        keyword_files.append((keyword, files))

    if not keyword_files:
        best = None
        for keyword in candidates:
            files = files_for(keyword)
            if not files:
                continue
            if best is None or len(files) < len(best[1]):
                best = (keyword, files)
        if best:
            keyword_files = [best]
            dropped = [(k, r) for k, r in dropped if k != best[0]]

    if not keyword_files:
        return {
            "question": question,
            "candidates": candidates,
            "dropped": dropped,
            "hits": [],
            "verdict": "MISS_EMPTY_KEYWORDS",
        }

    scores: dict[str, float] = {}
    for _, files in keyword_files:
        weight = 1.0 / len(files)
        for path in files:
            scores[path] = scores.get(path, 0.0) + weight + path_boost(path)

    top = sorted(scores.items(), key=lambda kv: (-kv[1], kv[0]))[:4]
    snippet_kws = sorted(keyword_files, key=lambda kf: len(kf[1]))[:3]
    pattern = "(" + "|".join(re.escape(k) for k, _ in snippet_kws) + ")"

    hits = []
    for path, score in top:
        out = rg(["-in", "-C", "2", "-m", "5", pattern, path], timeout=3.0)
        if not out:
            continue
        rel = path
        for root in roots:
            if path.startswith(root):
                rel = path[len(root) :].lstrip("/")
                break
        hits.append({"file": rel, "score": round(score, 4), "snippet_chars": len(out[:1500])})

    self_hits = sum(1 for h in hits if Path(h["file"]).name.startswith("call-"))
    doc_hits = sum(1 for h in hits if "docs/" in h["file"] or "scm-integrations" in h["file"])
    return {
        "question": question,
        "candidates": candidates,
        "kept": [(k, len(f)) for k, f in keyword_files],
        "dropped": dropped,
        "hits": hits,
        "self_hits": self_hits,
        "doc_hits": doc_hits,
        "verdict": "HIT" if hits else "MISS_NO_SNIPPETS",
    }


def main() -> int:
    roots = [str(Path("~/Projects/everysphere").expanduser())]
    sessions = Path("~/Library/Application Support/Cue/sessions").expanduser()
    if sessions.exists():
        roots.append(str(sessions))

    questions = DEFAULT_QUESTIONS
    if len(sys.argv) > 1:
        questions = sys.argv[1:]

    # Mimic excluding the active live session.
    exclude = {"call-2026-08-24_11-43-10.md"}

    hits = misses = self_top = 0
    for q in questions:
        result = search(q, roots, exclude=exclude)
        print("=" * 72)
        print(f"Q: {result['question']}")
        print(f"candidates: {result['candidates']}")
        print(f"kept: {result.get('kept')}")
        print(f"dropped: {result['dropped']}")
        print(f"verdict: {result['verdict']} doc_hits={result['doc_hits']} self_hits={result['self_hits']}")
        for hit in result["hits"]:
            print(f"  hit score={hit['score']} file={hit['file']} snippet_chars={hit['snippet_chars']}")
        if result["verdict"] == "HIT":
            hits += 1
            if result["hits"] and Path(result["hits"][0]["file"]).name.startswith("call-"):
                self_top += 1
        else:
            misses += 1

    print("=" * 72)
    print(f"SUMMARY hits={hits} misses={misses} self_ranked_first={self_top} total={hits + misses}")
    # Pass if we hit docs and never rank the live transcript first.
    return 0 if hits >= 7 and self_top == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
