from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import re
import time
from typing import Optional

_CHUNK_RE = re.compile(r"^out(\d+)\.wav$")


@dataclass(frozen=True)
class ChunkFile:
    index: int
    path: Path


def parse_chunk_index(path: Path) -> Optional[int]:
    match = _CHUNK_RE.match(path.name)
    if not match:
        return None
    return int(match.group(1))


def find_next_chunk(chunks_dir: Path, *, after_index: int) -> Optional[ChunkFile]:
    best: Optional[ChunkFile] = None
    for path in chunks_dir.glob("out*.wav"):
        idx = parse_chunk_index(path)
        if idx is None or idx <= after_index:
            continue
        if best is None or idx < best.index:
            best = ChunkFile(index=idx, path=path)
    return best


def find_next_completed_chunk(chunks_dir: Path, *, after_index: int) -> Optional[ChunkFile]:
    """
    Returns the next chunk that is *completed* (i.e., not the newest chunk on disk).

    With the ffmpeg segmenter, the newest chunk file is typically still being written.
    We avoid transcribing it until the next segment exists (or until shutdown, when we
    drain remaining chunks explicitly).
    """

    candidates: list[ChunkFile] = []
    for path in chunks_dir.glob("out*.wav"):
        idx = parse_chunk_index(path)
        if idx is None or idx <= after_index:
            continue
        candidates.append(ChunkFile(index=idx, path=path))

    if len(candidates) < 2:
        return None

    newest_index = max(c.index for c in candidates)
    completed = [c for c in candidates if c.index != newest_index]
    if not completed:
        return None
    return min(completed, key=lambda c: c.index)


def wait_for_file_stable(
    path: Path,
    *,
    stable_for_seconds: float = 0.75,
    poll_interval_seconds: float = 0.2,
    timeout_seconds: float = 30.0,
) -> None:
    start = time.monotonic()
    last_change = start
    last_sig: Optional[tuple[int, int]] = None

    while True:
        now = time.monotonic()
        if now - start > timeout_seconds:
            raise TimeoutError(f"Timed out waiting for file to stabilize: {path}")

        try:
            stat = path.stat()
        except FileNotFoundError:
            last_sig = None
            last_change = now
            time.sleep(poll_interval_seconds)
            continue

        sig = (stat.st_size, stat.st_mtime_ns)
        if last_sig is None or sig != last_sig:
            last_sig = sig
            last_change = now
        elif now - last_change >= stable_for_seconds:
            return

        time.sleep(poll_interval_seconds)


def max_chunk_index(chunks_dir: Path) -> int:
    maximum = -1
    for path in chunks_dir.glob("out*.wav"):
        idx = parse_chunk_index(path)
        if idx is None:
            continue
        maximum = max(maximum, idx)
    return maximum
