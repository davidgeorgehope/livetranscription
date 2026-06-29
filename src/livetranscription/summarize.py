from __future__ import annotations

import asyncio
import time
from typing import Optional


DEFAULT_SUMMARY_PROMPT = """You are a careful meeting summarizer.

Task:
- Update the running summary so it reflects everything covered so far.
- Prefer concise, factual bullet points.
- If the new transcript adds nothing, keep the summary effectively unchanged.
- Never drop a decision or action item that was in the previous summary unless the
  new transcript explicitly resolves, completes, or contradicts it. Carry them forward.

Action items — capture these aggressively:
- In real meetings, tasks are almost never announced as "action item:". They are
  phrased conversationally: "do me a favor and...", "can you work with X to...",
  "why don't you...", "you should...", "give her/him a...", "let's get...",
  "I'll...", "we need to...", "make sure...". Treat all of these as action items.
- Capture every commitment, request, and assignment, even small ones. Missing a
  real action item is far worse than including a borderline one.
- Attribute each item to an owner. Speaker diarization labels (e.g. "Speaker 1")
  are unreliable and may swap mid-transcript; prefer names used in direct address
  ("...David, can you...") and surrounding context over the labels.
- Include the deliverable and any stated deadline ("today", "by Friday",
  "before the meeting with X").
- If an item is completed during the meeting itself, keep it listed and mark it done.

Output format (Markdown):
## Summary
- ...

## Decisions
- ...

## Action items
- **Owner** — task (deadline if stated)

## Open questions
- ...
"""


def update_running_summary(
    *,
    previous_summary: str,
    new_transcript: str,
    model: str = "gemini-3.5-flash",
    prompt: str = DEFAULT_SUMMARY_PROMPT,
    temperature: float = 0.2,
    max_attempts: int = 3,
) -> str:
    if not new_transcript.strip():
        return previous_summary.strip()
    if max_attempts < 1:
        raise ValueError("max_attempts must be >= 1")

    from google import genai
    from google.genai import types

    client = genai.Client()  # Uses GEMINI_API_KEY env var

    full_prompt = (
        f"{prompt}\n\n"
        "Previous summary:\n"
        f"{previous_summary.strip() or '(none)'}\n\n"
        "New transcript:\n"
        f"{new_transcript.strip()}\n\n"
        "Updated running summary (includes everything so far):"
    )

    last_exc: Optional[BaseException] = None

    for attempt in range(1, max_attempts + 1):
        try:
            response = client.models.generate_content(
                model=model,
                contents=full_prompt,
                config=types.GenerateContentConfig(
                    temperature=temperature,
                    max_output_tokens=4000,
                ),
            )
            content = response.text
            if not content:
                raise RuntimeError("Empty summary response from model.")
            return content.strip()
        except Exception as exc:
            last_exc = exc
            if attempt < max_attempts:
                time.sleep(min(2**attempt, 8))

    assert last_exc is not None
    raise last_exc


async def update_running_summary_async(
    *,
    previous_summary: str,
    new_transcript: str,
    model: str = "gemini-3.5-flash",
    prompt: str = DEFAULT_SUMMARY_PROMPT,
    temperature: float = 0.2,
    max_attempts: int = 3,
) -> str:
    """Async wrapper for update_running_summary."""
    return await asyncio.to_thread(
        update_running_summary,
        previous_summary=previous_summary,
        new_transcript=new_transcript,
        model=model,
        prompt=prompt,
        temperature=temperature,
        max_attempts=max_attempts,
    )
