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
- Transcribe ONLY words that are actually spoken in this audio
- NEVER invent, imagine, or hallucinate speech that isn't there
- If the audio contains silence, background noise, music, or no clear speech, return: {"text": "(silence)", "segments": []}
- Identify distinct speakers and label them consistently (Speaker 1, Speaker 2, etc.)
- If only one speaker, still include segments with "Speaker 1"
- Estimate start/end times in seconds relative to the audio start
- Return ONLY valid JSON, no other text or markdown

CRITICAL: Only transcribe actual human speech you can clearly hear. When in doubt, return silence."""


def transcribe_file_gemini(
    path: Path,
    *,
    model: str = "gemini-3-flash-preview",
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

    from google import genai
    from google.genai import types

    client = genai.Client()  # Uses GEMINI_API_KEY env var

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
            response = client.models.generate_content(
                model=model,
                contents=[
                    prompt,
                    types.Part.from_bytes(data=audio_bytes, mime_type=mime_type),
                ],
                config=types.GenerateContentConfig(
                    temperature=0.1,  # Low temperature for accuracy
                    max_output_tokens=4000,
                    response_mime_type="application/json",
                ),
            )

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


def _extract_text_from_malformed_json(content: str) -> str:
    """Try to extract the text field from malformed JSON."""
    # Try to find "text": "..." pattern
    match = re.search(r'"text"\s*:\s*"([^"]*(?:\\.[^"]*)*)"', content)
    if match:
        # Unescape the string
        try:
            return json.loads(f'"{match.group(1)}"')
        except json.JSONDecodeError:
            return match.group(1)
    return ""


def _parse_transcript_response(content: str) -> TranscriptResult:
    """Parse the JSON response from Gemini into a TranscriptResult."""
    # Clean up potential markdown code blocks
    content = content.strip()
    if content.startswith("```"):
        content = re.sub(r"^```(?:json)?\n?", "", content)
        content = re.sub(r"\n?```$", "", content)

    try:
        data = json.loads(content)
    except json.JSONDecodeError:
        # If JSON parsing fails, try to extract text from malformed JSON
        extracted = _extract_text_from_malformed_json(content)
        if extracted:
            return TranscriptResult(text=extracted, segments=[])
        # If content looks like JSON (starts with {), it's malformed - return silence
        if content.strip().startswith("{"):
            print(f"[transcribe] Warning: Malformed JSON response, skipping: {content[:100]}...")
            return TranscriptResult(text="(transcription error)", segments=[])
        # Otherwise treat as plain text
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
    model: str = "gemini-3-flash-preview",
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
    model: str = "gemini-3-flash-preview",
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
    model: str = "gemini-3-flash-preview",
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
