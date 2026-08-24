#!/usr/bin/env python3
"""Prove SessionLibrary layout: list call-*.md and detect .wrap.md sidecars."""

from pathlib import Path

DIR = Path.home() / "Library/Application Support/Cue/sessions"


def main() -> int:
    assert DIR.exists(), f"missing {DIR}"
    calls = sorted(
        p for p in DIR.glob("call-*.md") if not p.name.endswith(".wrap.md")
    )
    print(f"sessions_dir={DIR}")
    print(f"call_count={len(calls)}")
    for p in calls:
        wrap = p.with_suffix(".wrap.md")
        # with_suffix replaces .md → .wrap.md incorrectly on "call-x.md"
        wrap = p.parent / (p.stem + ".wrap.md")
        lines = sum(1 for line in p.read_text(encoding="utf-8").splitlines() if line.startswith("- **"))
        print(f"  {p.name} lines={lines} wrap={wrap.exists()}")
    print("PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
