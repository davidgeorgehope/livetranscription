"""
Meeting prep context management for coaching.

Handles formatting meeting prep context for LLM prompts and
provides utilities for checking topic coverage.
"""

from __future__ import annotations

import re
from typing import Optional

from .session_store import (
    MeetingPrepContext,
    MeetingType,
    SessionPaths,
    TalkingPoint,
    load_meeting_prep,
    save_meeting_prep,
)


def format_meeting_prep_for_prompt(prep: MeetingPrepContext) -> str:
    """
    Format meeting prep context for inclusion in LLM coaching prompts.

    Returns a structured text representation optimized for LLM understanding.
    """
    sections = []

    # Meeting type
    type_descriptions = {
        MeetingType.SALES_CALL: "Sales call - focus on qualification, value prop, next steps",
        MeetingType.PRODUCT_DEMO: "Product demo - focus on features, use cases, addressing concerns",
        MeetingType.DISCOVERY_CALL: "Discovery call - focus on understanding needs, pain points, current solutions",
        MeetingType.NEGOTIATION: "Negotiation - focus on terms, objection handling, closing",
        MeetingType.CUSTOMER_SUCCESS: "Customer success - focus on value realization, adoption, expansion",
        MeetingType.INTERNAL_MEETING: "Internal meeting - focus on decisions, action items",
        MeetingType.ONE_ON_ONE: "1:1 meeting - focus on feedback, career development, blockers",
    }
    sections.append(f"Meeting type: {type_descriptions.get(prep.meeting_type, prep.meeting_type.value)}")

    # Attendees
    if prep.attendees:
        attendee_lines = []
        for a in prep.attendees:
            parts = [a.name]
            if a.role:
                parts.append(f"({a.role})")
            if a.company:
                parts.append(f"at {a.company}")
            if a.notes:
                parts.append(f"- {a.notes}")
            attendee_lines.append(" ".join(parts))
        sections.append("Attendees:\n" + "\n".join(f"  - {line}" for line in attendee_lines))

    # Objectives
    if prep.objectives:
        sections.append("Meeting objectives:\n" + "\n".join(f"  - {obj}" for obj in prep.objectives))

    # Talking points
    if prep.talking_points:
        priority_labels = {1: "[HIGH]", 2: "[MED]", 3: "[LOW]"}
        tp_lines = []
        for tp in prep.talking_points:
            status = "[COVERED]" if tp.mentioned else "[NOT YET]"
            priority = priority_labels.get(tp.priority, "")
            line = f"{status} {priority} {tp.topic}"
            if tp.notes:
                line += f" - {tp.notes}"
            tp_lines.append(line)
        sections.append("Talking points to cover:\n" + "\n".join(f"  - {line}" for line in tp_lines))

    # Competitors
    if prep.competitors:
        sections.append("Watch for competitor mentions: " + ", ".join(prep.competitors))

    # Pricing/discount info
    if prep.pricing_notes:
        sections.append(f"Pricing context: {prep.pricing_notes}")
    if prep.discount_authority:
        sections.append(f"Discount authority: {prep.discount_authority}")

    # Additional context
    if prep.additional_context:
        sections.append(f"Additional context: {prep.additional_context}")

    # Custom reminders
    if prep.custom_reminders:
        sections.append("Custom reminders:\n" + "\n".join(f"  - {r}" for r in prep.custom_reminders))

    return "\n\n".join(sections)


def get_uncovered_talking_points(prep: MeetingPrepContext) -> list[TalkingPoint]:
    """Get list of talking points that haven't been mentioned yet."""
    return [tp for tp in prep.talking_points if not tp.mentioned]


def get_high_priority_uncovered(prep: MeetingPrepContext) -> list[TalkingPoint]:
    """Get high-priority talking points that haven't been mentioned."""
    return [tp for tp in prep.talking_points if not tp.mentioned and tp.priority == 1]


def check_topic_mentioned(transcript: str, topic: str) -> bool:
    """
    Check if a topic appears to be mentioned in the transcript.

    Uses simple keyword matching. The coaching engine may do more
    sophisticated analysis with LLM.
    """
    # Simple case-insensitive check
    topic_lower = topic.lower()
    transcript_lower = transcript.lower()

    # Check for exact match or word boundary match
    pattern = rf"\b{re.escape(topic_lower)}\b"
    return bool(re.search(pattern, transcript_lower))


def find_competitor_mentions(
    transcript: str, competitors: list[str]
) -> list[tuple[str, str]]:
    """
    Find competitor mentions in transcript.

    Returns list of (competitor_name, context_snippet) tuples.
    """
    mentions = []
    transcript_lower = transcript.lower()

    for competitor in competitors:
        comp_lower = competitor.lower()
        pattern = rf"\b{re.escape(comp_lower)}\b"

        for match in re.finditer(pattern, transcript_lower):
            # Extract context around the mention (50 chars before and after)
            start = max(0, match.start() - 50)
            end = min(len(transcript), match.end() + 50)
            context = transcript[start:end]

            # Clean up context
            if start > 0:
                context = "..." + context
            if end < len(transcript):
                context = context + "..."

            mentions.append((competitor, context))

    return mentions


def update_topic_coverage(
    paths: SessionPaths,
    transcript_chunk: str,
) -> list[str]:
    """
    Check transcript chunk for mentioned topics and update meeting prep.

    Returns list of newly covered topics.
    """
    prep = load_meeting_prep(paths)
    if prep is None:
        return []

    newly_covered = []

    for tp in prep.talking_points:
        if not tp.mentioned and check_topic_mentioned(transcript_chunk, tp.topic):
            tp.mentioned = True
            from datetime import datetime

            tp.mentioned_at = datetime.now().isoformat(timespec="seconds")
            newly_covered.append(tp.topic)

    if newly_covered:
        save_meeting_prep(paths, prep)

    return newly_covered


def get_meeting_type_coaching_hints(meeting_type: MeetingType) -> dict[str, str]:
    """
    Get coaching hints specific to the meeting type.

    Returns a dict with keys like 'focus', 'good_questions', 'watch_for'.
    """
    hints = {
        MeetingType.SALES_CALL: {
            "focus": "Qualification and moving to next steps",
            "good_questions": "Budget, timeline, decision makers, current solution pain points",
            "watch_for": "Buying signals, objections, competitor mentions",
        },
        MeetingType.PRODUCT_DEMO: {
            "focus": "Showing value through relevant features",
            "good_questions": "Which features matter most, current workflow, success criteria",
            "watch_for": "Confusion, feature requests, comparison questions",
        },
        MeetingType.DISCOVERY_CALL: {
            "focus": "Understanding their situation deeply",
            "good_questions": "Current challenges, ideal outcome, stakeholders affected",
            "watch_for": "Pain points, urgency indicators, budget hints",
        },
        MeetingType.NEGOTIATION: {
            "focus": "Finding mutually beneficial terms",
            "good_questions": "Key priorities, flexibility areas, timeline constraints",
            "watch_for": "Anchoring attempts, deadlines, walk-away signals",
        },
        MeetingType.CUSTOMER_SUCCESS: {
            "focus": "Ensuring they're getting value",
            "good_questions": "Usage patterns, challenges faced, expansion opportunities",
            "watch_for": "Churn signals, upsell opportunities, reference potential",
        },
        MeetingType.INTERNAL_MEETING: {
            "focus": "Making decisions and assigning actions",
            "good_questions": "Blockers, dependencies, priorities",
            "watch_for": "Unclear ownership, scope creep, missing stakeholders",
        },
        MeetingType.ONE_ON_ONE: {
            "focus": "Supporting the other person",
            "good_questions": "How can I help, what's blocking you, career goals",
            "watch_for": "Unspoken concerns, morale signals, growth opportunities",
        },
    }

    return hints.get(meeting_type, {})
