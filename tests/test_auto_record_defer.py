import asyncio
from datetime import datetime, timedelta, timezone

import livetranscription.server as server
from livetranscription.server import _auto_record_runtime, _run_auto_record_check, DevicesUnavailableError
from livetranscription.app_settings import AppSettings, SavedAudioDevice
from livetranscription.calendar_auto_record import CalendarMeeting


def _meeting(now):
    return CalendarMeeting(
        event_id="primary:evt1",
        title="Customer call",
        start=now,
        end=now + timedelta(minutes=30),
        attendees=["c@example.com"],
        meeting_url="https://meet.google.com/x",
    )


def _settings():
    return AppSettings(
        auto_record_enabled=True,
        default_devices=[SavedAudioDevice(index=3, name="David’s AirPods Max #2")],
        google_calendar_credentials_path="/tmp/whatever.json",
    )


def _reset_runtime():
    _auto_record_runtime.started_event_ids = {}
    _auto_record_runtime.pending_meeting = None
    _auto_record_runtime.last_error = None


def test_auto_record_defers_then_starts_when_devices_connect(monkeypatch):
    _reset_runtime()
    now = datetime.now(timezone.utc)
    meeting = _meeting(now)

    monkeypatch.setattr(server, "_has_active_recording_session", lambda: False)
    monkeypatch.setattr(server, "fetch_google_calendar_meetings", lambda *a, **k: [meeting])

    # First poll: devices missing -> meeting is deferred, not dropped or started.
    async def fail_start(settings, m):
        raise DevicesUnavailableError(["David’s AirPods Max #2"])

    monkeypatch.setattr(server, "_start_auto_recording_for_meeting", fail_start)

    settings = _settings()
    asyncio.run(_run_auto_record_check(settings))

    assert _auto_record_runtime.pending_meeting is meeting
    assert "Waiting for audio devices" in (_auto_record_runtime.last_error or "")
    assert meeting.event_id not in _auto_record_runtime.started_event_ids

    # Later poll: meeting has fallen out of the calendar window, but the mics
    # are now connected -> the deferred meeting still gets started.
    monkeypatch.setattr(server, "fetch_google_calendar_meetings", lambda *a, **k: [])
    started = {}

    async def ok_start(settings, m):
        started["id"] = m.event_id
        _auto_record_runtime.started_event_ids[m.event_id] = datetime.now()

    monkeypatch.setattr(server, "_start_auto_recording_for_meeting", ok_start)

    asyncio.run(_run_auto_record_check(settings))

    assert started.get("id") == meeting.event_id
    assert _auto_record_runtime.pending_meeting is None


def test_auto_record_drops_pending_after_meeting_ends(monkeypatch):
    _reset_runtime()
    now = datetime.now(timezone.utc)
    _auto_record_runtime.pending_meeting = CalendarMeeting(
        event_id="primary:old",
        title="Past",
        start=now - timedelta(hours=2),
        end=now - timedelta(minutes=1),
        attendees=[],
    )

    monkeypatch.setattr(server, "_has_active_recording_session", lambda: False)
    monkeypatch.setattr(server, "fetch_google_calendar_meetings", lambda *a, **k: [])

    asyncio.run(_run_auto_record_check(_settings()))

    assert _auto_record_runtime.pending_meeting is None
