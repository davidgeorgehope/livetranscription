from __future__ import annotations

from dataclasses import asdict, dataclass
from datetime import datetime
import json
from pathlib import Path
from typing import Any, Optional


@dataclass
class SessionState:
    created_at: str
    chunk_seconds: int
    last_processed_index: int = -1
    last_summarized_index: int = -1
    summary: str = ""

    @staticmethod
    def new(*, chunk_seconds: int) -> "SessionState":
        return SessionState(created_at=datetime.now().isoformat(timespec="seconds"), chunk_seconds=chunk_seconds)

    @staticmethod
    def from_json(data: dict[str, Any]) -> "SessionState":
        return SessionState(
            created_at=str(data.get("created_at", "")),
            chunk_seconds=int(data.get("chunk_seconds", 30)),
            last_processed_index=int(data.get("last_processed_index", -1)),
            last_summarized_index=int(data.get("last_summarized_index", -1)),
            summary=str(data.get("summary", "")),
        )


@dataclass(frozen=True)
class SessionPaths:
    session_dir: Path
    chunks_dir: Path
    failed_dir: Path
    transcript_txt: Path
    transcript_jsonl: Path
    summary_md: Path
    state_json: Path
    ffmpeg_log: Path


def resolve_session_paths(session_dir: Path) -> SessionPaths:
    return SessionPaths(
        session_dir=session_dir,
        chunks_dir=session_dir / "chunks",
        failed_dir=session_dir / "failed_chunks",
        transcript_txt=session_dir / "transcript.txt",
        transcript_jsonl=session_dir / "transcript.jsonl",
        summary_md=session_dir / "summary.md",
        state_json=session_dir / "state.json",
        ffmpeg_log=session_dir / "ffmpeg.log",
    )


def init_session_dir(paths: SessionPaths) -> None:
    paths.session_dir.mkdir(parents=True, exist_ok=True)
    paths.chunks_dir.mkdir(parents=True, exist_ok=True)
    paths.failed_dir.mkdir(parents=True, exist_ok=True)


def load_state(paths: SessionPaths) -> Optional[SessionState]:
    if not paths.state_json.exists():
        return None
    data = json.loads(paths.state_json.read_text(encoding="utf-8"))
    return SessionState.from_json(data)


def save_state(paths: SessionPaths, state: SessionState) -> None:
    paths.state_json.write_text(json.dumps(asdict(state), indent=2, sort_keys=True) + "\n", encoding="utf-8")


def append_jsonl(paths: SessionPaths, obj: dict[str, Any]) -> None:
    with paths.transcript_jsonl.open("a", encoding="utf-8") as f:
        f.write(json.dumps(obj, ensure_ascii=False) + "\n")


def format_hhmmss(total_seconds: int) -> str:
    hours = total_seconds // 3600
    minutes = (total_seconds % 3600) // 60
    seconds = total_seconds % 60
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}"


def append_transcript_text(paths: SessionPaths, *, chunk_index: int, chunk_seconds: int, text: str) -> None:
    offset = format_hhmmss(chunk_index * chunk_seconds)
    line = f"[{offset}] {text.strip()}\n"
    with paths.transcript_txt.open("a", encoding="utf-8") as f:
        f.write(line)


def write_summary(paths: SessionPaths, *, summary: str, updated_at: Optional[str] = None) -> None:
    if updated_at is None:
        updated_at = datetime.now().isoformat(timespec="seconds")
    content = f"# Running summary\n\nLast updated: {updated_at}\n\n{summary.strip()}\n"
    paths.summary_md.write_text(content, encoding="utf-8")


def load_transcript_since(paths: SessionPaths, *, after_index: int) -> list[tuple[int, str]]:
    if not paths.transcript_jsonl.exists():
        return []
    out: list[tuple[int, str]] = []
    for line in paths.transcript_jsonl.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        idx = obj.get("index")
        text = obj.get("text")
        if not isinstance(idx, int) or not isinstance(text, str):
            continue
        if idx > after_index and text.strip():
            out.append((idx, text))
    out.sort(key=lambda t: t[0])
    return out

