from datetime import datetime, timedelta, timezone

from livetranscription.app_settings import AppSettings
from livetranscription.calendar_auto_record import _event_to_meeting


def test_event_to_meeting_includes_meeting_starting_soon():
    now = datetime(2026, 5, 26, 15, 0, tzinfo=timezone.utc)
    event = {
        "id": "abc123",
        "summary": "Customer call",
        "start": {"dateTime": (now + timedelta(minutes=1)).isoformat()},
        "end": {"dateTime": (now + timedelta(minutes=31)).isoformat()},
        "hangoutLink": "https://meet.google.com/aaa-bbbb-ccc",
        "attendees": [
            {"self": True, "responseStatus": "accepted", "email": "me@example.com"},
            {"email": "customer@example.com"},
        ],
    }

    meeting = _event_to_meeting(
        event,
        calendar_id="primary",
        settings=AppSettings(auto_record_enabled=True),
        now=now,
    )

    assert meeting is not None
    assert meeting.event_id == "primary:abc123"
    assert meeting.title == "Customer call"
    assert meeting.meeting_url == "https://meet.google.com/aaa-bbbb-ccc"
    assert meeting.attendees == ["customer@example.com"]


def test_event_to_meeting_skips_events_without_link_when_required():
    now = datetime(2026, 5, 26, 15, 0, tzinfo=timezone.utc)
    event = {
        "id": "abc123",
        "summary": "No link",
        "start": {"dateTime": (now + timedelta(minutes=1)).isoformat()},
        "end": {"dateTime": (now + timedelta(minutes=31)).isoformat()},
    }

    meeting = _event_to_meeting(
        event,
        calendar_id="primary",
        settings=AppSettings(auto_record_enabled=True),
        now=now,
    )

    assert meeting is None


def test_event_to_meeting_skips_declined_self_attendee():
    now = datetime(2026, 5, 26, 15, 0, tzinfo=timezone.utc)
    event = {
        "id": "abc123",
        "summary": "Declined",
        "start": {"dateTime": (now + timedelta(minutes=1)).isoformat()},
        "end": {"dateTime": (now + timedelta(minutes=31)).isoformat()},
        "hangoutLink": "https://meet.google.com/aaa-bbbb-ccc",
        "attendees": [
            {"self": True, "responseStatus": "declined", "email": "me@example.com"},
        ],
    }

    meeting = _event_to_meeting(
        event,
        calendar_id="primary",
        settings=AppSettings(auto_record_enabled=True),
        now=now,
    )

    assert meeting is None
