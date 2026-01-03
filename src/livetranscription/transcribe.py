"""
Audio transcription using Google Gemini's multimodal API.

Supports speaker diarization for distinguishing multiple speakers.
"""

from __future__ import annotations

import asyncio
import base64
import json
import re
import time
from pathlib import Path
from typing import Optional

from .session_store import TranscriptResult, TranscriptSegment


TRANSCRIPTION_PROMPT = """Transcribe this audio verbatim and accurately.

Return your response as valid JSON with this exact format:
{
  "text": "the complete transcript as a single string",
  "segments": [
    {"speaker": "Speaker 1", "text": "what they said", "start": 0.0, "end": 2.5},
    {"speaker": "Speaker 2", "text": "what they said", "start": 2.5, "end": 5.0}
  ]
}

Instructions:
- Transcribe ALL spoken words exactly as said
- Identify distinct speakers and label them consistently (Speaker 1, Speaker 2, etc.)
- If only one speaker, still include segments with "Speaker 1"
- Estimate start/end times in seconds relative to the audio start
- If the audio is silent or contains no speech, return: {"text": "(silence)", "segments": []}
- Return ONLY valid JSON, no other text or markdown"""


def transcribe_file_gemini(
    path: Path,
    *,
    model: str = "gemini-3-pro-preview",
    language: Optional[str] = None,
    diarize: bool = True,
    max_attempts: int = 3,
) -> TranscriptResult:
    """
    Transcribe an audio file using Gemini's multimodal API.

    Args:
        path: Path to the audio file (WAV, MP3, etc.)
        model: Gemini model to use
        language: Optional language hint (not currently used but kept for API compat)
        diarize: Whether to perform speaker diarization
        max_attempts: Number of retry attempts

    Returns:
        TranscriptResult with text and optional speaker segments
    """
    if max_attempts < 1:
        raise ValueError("max_attempts must be >= 1")

    import google.generativeai as genai

    genai.configure()  # Uses GOOGLE_API_KEY env var

    gemini_model = genai.GenerativeModel(
        model,
        generation_config={
            "temperature": 0.1,  # Low temperature for accuracy
            "max_output_tokens": 4000,
            "response_mime_type": "application/json",
        },
    )

    # Read audio file as bytes
    audio_bytes = path.read_bytes()

    # Determine MIME type from extension
    suffix = path.suffix.lower()
    mime_types = {
        ".wav": "audio/wav",
        ".mp3": "audio/mpeg",
        ".aiff": "audio/aiff",
        ".aac": "audio/aac",
        ".ogg": "audio/ogg",
        ".flac": "audio/flac",
    }
    mime_type = mime_types.get(suffix, "audio/wav")

    # Build prompt
    prompt = TRANSCRIPTION_PROMPT
    if language:
        prompt += f"\n\nThe audio is in {language}."
    if not diarize:
        prompt = prompt.replace(
            "Identify distinct speakers and label them consistently",
            "Label all speech as 'Speaker 1'"
        )

    last_exc: Optional[BaseException] = None

    for attempt in range(1, max_attempts + 1):
        try:
            response = gemini_model.generate_content([
                prompt,
                {"mime_type": mime_type, "data": audio_bytes},
            ])

            content = response.text
            if not content:
                raise RuntimeError("Empty response from Gemini")

            return _parse_transcript_response(content)

        except Exception as exc:
            last_exc = exc
            if attempt < max_attempts:
                time.sleep(min(2 ** attempt, 8))

    assert last_exc is not None
    raise last_exc


def _parse_transcript_response(content: str) -> TranscriptResult:
    """Parse the JSON response from Gemini into a TranscriptResult."""
    # Clean up potential markdown code blocks
    content = content.strip()
    if content.startswith("```"):
        content = re.sub(r"^```(?:json)?\n?", "", content)
        content = re.sub(r"\n?```$", "", content)

    try:
        data = json.loads(content)
    except json.JSONDecodeError as e:
        # If JSON parsing fails, return as plain text
        return TranscriptResult(text=content.strip() or "(silence)", segments=[])

    text = data.get("text", "")
    if not text or text.strip() == "":
        text = "(silence)"

    segments = []
    for seg_data in data.get("segments", []):
        segments.append(TranscriptSegment(
            speaker=seg_data.get("speaker", "Speaker 1"),
            text=seg_data.get("text", ""),
            start_time=float(seg_data.get("start", 0)),
            end_time=float(seg_data.get("end", 0)),
        ))

    return TranscriptResult(text=text, segments=segments)


async def transcribe_file_gemini_async(
    path: Path,
    *,
    model: str = "gemini-3-pro-preview",
    language: Optional[str] = None,
    diarize: bool = True,
    max_attempts: int = 3,
) -> TranscriptResult:
    """Async wrapper for transcribe_file_gemini."""
    return await asyncio.to_thread(
        transcribe_file_gemini,
        path,
        model=model,
        language=language,
        diarize=diarize,
        max_attempts=max_attempts,
    )


# Backward compatibility aliases
def transcribe_file_whisper(
    path: Path,
    *,
    model: str = "gemini-3-pro-preview",
    language: Optional[str] = None,
    max_attempts: int = 3,
) -> str:
    """
    Backward compatible function that returns just the text.

    Deprecated: Use transcribe_file_gemini() instead.
    """
    result = transcribe_file_gemini(
        path,
        model=model,
        language=language,
        diarize=False,
        max_attempts=max_attempts,
    )
    return result.text


async def transcribe_file_whisper_async(
    path: Path,
    *,
    model: str = "gemini-3-pro-preview",
    language: Optional[str] = None,
    max_attempts: int = 3,
) -> str:
    """
    Backward compatible async function that returns just the text.

    Deprecated: Use transcribe_file_gemini_async() instead.
    """
    result = await transcribe_file_gemini_async(
        path,
        model=model,
        language=language,
        diarize=False,
        max_attempts=max_attempts,
    )
    return result.text
