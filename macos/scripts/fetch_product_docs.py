#!/usr/bin/env python3
"""Refresh the `product-docs/` knowledge pack from public cursor.com docs.

cursor.com/docs serves each page as clean markdown at `<path>.md`. These are
the statements we make publicly, so Cue ranks them above internal-docs and code
for product behaviour (see MeetingType.sourcedSystemPrompt and SourceSearch).

Usage:
  python3 fetch_product_docs.py                # the default page list below
  python3 fetch_product_docs.py grok-bot/teams # extra doc paths
"""
from __future__ import annotations

import sys
import urllib.request
from datetime import date
from pathlib import Path

PACK = Path.home() / "Library/Application Support/Cue/knowledge/product-docs"
BASE = "https://cursor.com/docs/"
DEFAULT_PAGES = [
    "grok-bot/security",
    "grok-bot/security-faq",
    "grok-bot/identity",
    "grok-bot/private-networks",
    "grok-bot/teams",
    "cloud-agent/security",
    "cloud-agent/security-network",
]


def fetch(path: str) -> str:
    req = urllib.request.Request(BASE + path + ".md", headers={"User-Agent": "Mozilla/5.0 (Cue)"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode("utf-8", "replace")


def main(argv: list[str]) -> int:
    pages = DEFAULT_PAGES + [a.strip("/").removesuffix(".md") for a in argv]
    PACK.mkdir(parents=True, exist_ok=True)
    for path in pages:
        try:
            text = fetch(path)
        except Exception as e:  # noqa: BLE001
            print(f"  ! {path}: {e}", file=sys.stderr)
            continue
        if not text.lstrip().startswith("#"):
            print(f"  ! {path}: not markdown, skipped", file=sys.stderr)
            continue
        dest = PACK / (path.replace("/", "--") + ".md")
        header = f"<!-- source: {BASE}{path} · fetched {date.today().isoformat()} · public product doc -->\n"
        dest.write_text(header + text, encoding="utf-8")
        print(f"wrote {dest.name} ({len(text)} chars)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
