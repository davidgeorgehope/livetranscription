"""
Real-time coaching engine for live meeting analysis.

Analyzes transcript chunks and generates coaching suggestions
including objection handling, suggested questions, and alerts.
"""

from __future__ import annotations

import json
import re
import time
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Optional

from .events import (
    EVENT_COACHING_ALERT,
    EVENT_COMPETITOR_MENTION,
    EVENT_PACE_WARNING,
    Event,
    get_event_bus,
)
from .meeting_prep import (
    find_competitor_mentions,
    format_meeting_prep_for_prompt,
    get_high_priority_uncovered,
    get_meeting_type_coaching_hints,
    update_topic_coverage,
)
from .session_store import (
    AlertType,
    CoachingAlert,
    MeetingPrepContext,
    SessionPaths,
    append_coaching_alert,
)


# Coaching prompt template - single batched call for efficiency
COACHING_PROMPT = """You are a real-time meeting coach. Analyze the latest transcript segment in the context of this meeting and provide actionable coaching.

MEETING CONTEXT:
{meeting_context}

TRANSCRIPT SO FAR (last 5 minutes for context):
{recent_transcript}

NEW SEGMENT TO ANALYZE:
{new_segment}

Based on this, provide coaching in the following JSON format. Be concise and actionable. Only include items that are clearly relevant - don't force suggestions.

{{
  "objections": [
    {{
      "detected": "The objection or concern raised",
      "response": "Suggested response to address it"
    }}
  ],
  "suggested_questions": [
    {{
      "question": "A good question to ask now",
      "reason": "Why this question would be valuable"
    }}
  ],
  "missing_topics": [
    {{
      "topic": "Topic from meeting prep not yet covered",
      "suggestion": "How to naturally bring it up"
    }}
  ],
  "competitor_insights": [
    {{
      "competitor": "Competitor name mentioned",
      "context": "What was said about them",
      "talking_point": "How to respond or position against them"
    }}
  ],
  "observations": [
    {{
      "type": "info|warning|opportunity",
      "content": "Notable observation about the conversation"
    }}
  ]
}}

Important:
- Only return valid JSON, no other text
- Keep suggestions brief and immediately actionable
- Focus on the NEW SEGMENT - don't repeat analysis of old content
- If nothing notable in this segment, return empty arrays
"""


@dataclass
class PaceTracker:
    """Tracks speaking pace to detect when user is talking too long."""

    continuous_speaking_start: Optional[float] = None
    last_chunk_had_content: bool = False
    warning_threshold_minutes: float = 4.0
    last_warning_time: Optional[float] = None
    warning_cooldown_seconds: float = 120.0  # Don't warn again for 2 minutes

    def update(self, chunk_text: str) -> Optional[str]:
        """
        Update pace tracking with new chunk.

        Returns a warning message if user has been talking too long.
        """
        now = time.time()
        has_content = bool(chunk_text.strip()) and chunk_text.strip() != "(silence)"

        if has_content:
            if not self.last_chunk_had_content:
                # Started speaking
                self.continuous_speaking_start = now
            elif self.continuous_speaking_start:
                # Check if we've been talking too long
                duration_minutes = (now - self.continuous_speaking_start) / 60

                if duration_minutes >= self.warning_threshold_minutes:
                    # Check cooldown
                    if (
                        self.last_warning_time is None
                        or (now - self.last_warning_time) > self.warning_cooldown_seconds
                    ):
                        self.last_warning_time = now
                        return f"You've been talking for {duration_minutes:.1f} minutes straight. Consider pausing for questions or input."
        else:
            # Silence - reset the counter
            self.continuous_speaking_start = None

        self.last_chunk_had_content = has_content
        return None


@dataclass
class CoachingResult:
    """Results from coaching analysis."""

    alerts: list[CoachingAlert] = field(default_factory=list)
    topics_covered: list[str] = field(default_factory=list)


class CoachingEngine:
    """
    Real-time coaching engine that analyzes transcript chunks.

    Uses a combination of local heuristics and LLM analysis for
    cost-effective coaching suggestions.
    """

    def __init__(
        self,
        model: str = "gemini-3-flash-preview",
        enabled: bool = True,
    ) -> None:
        self.model = model
        self.enabled = enabled
        self.pace_tracker = PaceTracker()
        self._recent_transcript: list[str] = []  # Rolling window of recent chunks
        self._max_recent_chunks = 10  # ~5 minutes at 30-second chunks
        self._gemini_model = None

    async def analyze_chunk(
        self,
        paths: SessionPaths,
        prep: Optional[MeetingPrepContext],
        chunk_text: str,
        session_id: str,
    ) -> CoachingResult:
        """
        Analyze a new transcript chunk and generate coaching.

        Args:
            paths: Session paths for persistence
            prep: Meeting prep context (may be None)
            chunk_text: The new transcript chunk text
            session_id: Session ID for events

        Returns:
            CoachingResult with alerts and covered topics
        """
        if not self.enabled:
            return CoachingResult()

        result = CoachingResult()
        event_bus = get_event_bus()

        # Update recent transcript window
        self._recent_transcript.append(chunk_text)
        if len(self._recent_transcript) > self._max_recent_chunks:
            self._recent_transcript.pop(0)

        # 1. Local pace detection (no LLM cost)
        pace_warning = self.pace_tracker.update(chunk_text)
        if pace_warning:
            alert = CoachingAlert(
                id="",
                alert_type=AlertType.PACE_WARNING,
                content=pace_warning,
            )
            result.alerts.append(alert)
            append_coaching_alert(paths, alert)
            await event_bus.publish(
                Event(
                    type=EVENT_PACE_WARNING,
                    data={"minutes_talking": self.pace_tracker.warning_threshold_minutes, "message": pace_warning},
                    session_id=session_id,
                )
            )

        # Skip LLM analysis if no meeting prep or chunk is silence
        if not prep or not chunk_text.strip() or chunk_text.strip() == "(silence)":
            return result

        # 2. Local competitor detection (fast regex)
        if prep.competitors:
            mentions = find_competitor_mentions(chunk_text, prep.competitors)
            for competitor, context in mentions:
                alert = CoachingAlert(
                    id="",
                    alert_type=AlertType.COMPETITOR_MENTION,
                    content=f"Competitor mentioned: {competitor}",
                    metadata={"competitor": competitor, "context": context},
                )
                result.alerts.append(alert)
                append_coaching_alert(paths, alert)
                await event_bus.publish(
                    Event(
                        type=EVENT_COMPETITOR_MENTION,
                        data={"competitor": competitor, "context": context},
                        session_id=session_id,
                    )
                )

        # 3. Local topic coverage check
        newly_covered = update_topic_coverage(paths, chunk_text)
        result.topics_covered = newly_covered

        # 4. LLM analysis for deeper insights
        try:
            llm_alerts = await self._analyze_with_llm(prep, chunk_text, session_id)
            for alert in llm_alerts:
                result.alerts.append(alert)
                append_coaching_alert(paths, alert)
                await event_bus.publish(
                    Event(
                        type=EVENT_COACHING_ALERT,
                        data=alert.to_dict(),
                        session_id=session_id,
                    )
                )
        except Exception as e:
            # Log but don't fail on LLM errors
            print(f"[coaching] LLM analysis error: {e}")

        return result

    def _get_gemini_model(self):
        """Get or create the Gemini model instance."""
        if self._gemini_model is None:
            import google.generativeai as genai

            genai.configure()  # Uses GOOGLE_API_KEY env var
            self._gemini_model = genai.GenerativeModel(
                self.model,
                generation_config={
                    "temperature": 0.3,
                    "max_output_tokens": 1000,
                    "response_mime_type": "application/json",
                },
            )
        return self._gemini_model

    async def _analyze_with_llm(
        self,
        prep: MeetingPrepContext,
        chunk_text: str,
        session_id: str,
    ) -> list[CoachingAlert]:
        """
        Run LLM analysis on the chunk.

        Uses a single batched prompt for cost efficiency.
        """
        import asyncio

        # Build the prompt
        meeting_context = format_meeting_prep_for_prompt(prep)
        recent_transcript = "\n".join(self._recent_transcript[:-1])  # Exclude current chunk

        # Add meeting type hints
        hints = get_meeting_type_coaching_hints(prep.meeting_type)
        if hints:
            meeting_context += "\n\nCoaching focus:\n"
            for key, value in hints.items():
                meeting_context += f"  - {key}: {value}\n"

        prompt = COACHING_PROMPT.format(
            meeting_context=meeting_context,
            recent_transcript=recent_transcript or "(conversation just started)",
            new_segment=chunk_text,
        )

        full_prompt = "You are a real-time meeting coach. Return only valid JSON.\n\n" + prompt

        # Call Gemini
        model = self._get_gemini_model()
        response = await asyncio.to_thread(
            model.generate_content,
            full_prompt,
        )

        content = response.text
        if not content:
            return []

        # Parse the JSON response
        try:
            # Handle potential markdown code blocks
            content = content.strip()
            if content.startswith("```"):
                content = re.sub(r"^```(?:json)?\n?", "", content)
                content = re.sub(r"\n?```$", "", content)

            data = json.loads(content)
        except json.JSONDecodeError:
            return []

        alerts: list[CoachingAlert] = []

        # Process objections
        for obj in data.get("objections", []):
            alert = CoachingAlert(
                id="",
                alert_type=AlertType.OBJECTION,
                content=obj.get("detected", ""),
                suggestion=obj.get("response"),
            )
            if alert.content:
                alerts.append(alert)

        # Process suggested questions
        for q in data.get("suggested_questions", []):
            alert = CoachingAlert(
                id="",
                alert_type=AlertType.SUGGESTED_QUESTION,
                content=q.get("question", ""),
                suggestion=q.get("reason"),
            )
            if alert.content:
                alerts.append(alert)

        # Process missing topics
        for topic in data.get("missing_topics", []):
            alert = CoachingAlert(
                id="",
                alert_type=AlertType.MISSING_TOPIC,
                content=f"Haven't mentioned: {topic.get('topic', '')}",
                suggestion=topic.get("suggestion"),
            )
            if alert.content:
                alerts.append(alert)

        # Process competitor insights (supplement local detection)
        for comp in data.get("competitor_insights", []):
            alert = CoachingAlert(
                id="",
                alert_type=AlertType.COMPETITOR_MENTION,
                content=f"{comp.get('competitor', '')}: {comp.get('context', '')}",
                suggestion=comp.get("talking_point"),
            )
            if alert.content:
                alerts.append(alert)

        # Process general observations
        for obs in data.get("observations", []):
            if obs.get("type") == "opportunity":
                alert = CoachingAlert(
                    id="",
                    alert_type=AlertType.CUSTOM_REMINDER,
                    content=obs.get("content", ""),
                    metadata={"observation_type": obs.get("type")},
                )
                if alert.content:
                    alerts.append(alert)

        return alerts

    def reset(self) -> None:
        """Reset the coaching engine state for a new session."""
        self.pace_tracker = PaceTracker()
        self._recent_transcript = []


# Global coaching engine instance
_coaching_engine: Optional[CoachingEngine] = None


def get_coaching_engine(model: str = "gpt-4o-mini") -> CoachingEngine:
    """Get or create the global coaching engine instance."""
    global _coaching_engine
    if _coaching_engine is None:
        _coaching_engine = CoachingEngine(model=model)
    return _coaching_engine


def reset_coaching_engine() -> None:
    """Reset the global coaching engine."""
    global _coaching_engine
    if _coaching_engine:
        _coaching_engine.reset()
    _coaching_engine = None
