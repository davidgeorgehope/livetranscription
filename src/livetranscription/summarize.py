from __future__ import annotations

import time
from typing import Optional


DEFAULT_SUMMARY_PROMPT = """You are a careful meeting summarizer.

Task:
- Update the running summary so it reflects everything covered so far.
- Prefer concise, factual bullet points.
- If the new transcript adds nothing, keep the summary effectively unchanged.

Output format (Markdown):
## Summary
- ...

## Decisions
- ...

## Action items
- ...

## Open questions
- ...
"""


def update_running_summary(
    *,
    previous_summary: str,
    new_transcript: str,
    model: str,
    prompt: str = DEFAULT_SUMMARY_PROMPT,
    temperature: float = 0.2,
    max_attempts: int = 3,
) -> str:
    if not new_transcript.strip():
        return previous_summary.strip()
    if max_attempts < 1:
        raise ValueError("max_attempts must be >= 1")

    from openai import OpenAI  # type: ignore

    client = OpenAI()
    last_exc: Optional[BaseException] = None

    messages = [
        {"role": "system", "content": prompt},
        {
            "role": "user",
            "content": (
                "Previous summary:\n"
                f"{previous_summary.strip() or '(none)'}\n\n"
                "New transcript:\n"
                f"{new_transcript.strip()}\n\n"
                "Updated running summary (includes everything so far):"
            ),
        },
    ]

    for attempt in range(1, max_attempts + 1):
        try:
            resp = client.chat.completions.create(
                model=model,
                messages=messages,
                temperature=temperature,
            )
            content = resp.choices[0].message.content
            if not content:
                raise RuntimeError("Empty summary response from model.")
            return content.strip()
        except Exception as exc:
            last_exc = exc
            if attempt < max_attempts:
                time.sleep(min(2**attempt, 8))

    assert last_exc is not None
    raise last_exc
