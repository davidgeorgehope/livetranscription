from __future__ import annotations

from pathlib import Path
import time
from typing import Optional


def transcribe_file_whisper(
    path: Path,
    *,
    model: str = "whisper-1",
    language: Optional[str] = None,
    max_attempts: int = 3,
) -> str:
    if max_attempts < 1:
        raise ValueError("max_attempts must be >= 1")

    # Import lazily so `livetranscribe devices` can run even if openai isn't installed yet.
    from openai import OpenAI  # type: ignore

    client = OpenAI()
    last_exc: Optional[BaseException] = None

    for attempt in range(1, max_attempts + 1):
        try:
            with path.open("rb") as f:
                resp = client.audio.transcriptions.create(
                    model=model,
                    file=f,
                    language=language,
                )
            text = getattr(resp, "text", None)
            if isinstance(text, str):
                return text.strip()
            if isinstance(resp, str):
                return resp.strip()
            raise TypeError(f"Unexpected transcription response type: {type(resp)}")
        except Exception as exc:
            last_exc = exc
            if attempt < max_attempts:
                time.sleep(min(2**attempt, 8))

    assert last_exc is not None
    raise last_exc
