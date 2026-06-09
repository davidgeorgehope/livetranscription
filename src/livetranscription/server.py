"""
FastAPI server with REST and WebSocket endpoints for real-time transcription coaching.
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import signal
import subprocess
import time
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Optional

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from .api_models import (
    AppSettingsResponse,
    AppSettingsUpdate,
    AutoRecordStatusResponse,
    CoachingHistoryResponse,
    ConfiguredDeviceStatus,
    DeviceInfo,
    DeviceListResponse,
    DeviceStatusResponse,
    MeetingPrepCreate,
    MeetingPrepResponse,
    SavedAudioDevice,
    SessionCreate,
    SessionListResponse,
    SessionResponse,
    SessionStatus,
    SummaryResponse,
    TalkingPointResponse,
    TranscriptChunk,
    TranscriptResponse,
)
from .app_settings import (
    AppSettings as StoredAppSettings,
    SavedAudioDevice as StoredSavedAudioDevice,
    load_app_settings,
    save_app_settings,
)
from .calendar_auto_record import CalendarMeeting, fetch_google_calendar_meetings
from .coaching import get_coaching_engine, reset_coaching_engine
from .events import EVENT_CHUNK_TRANSCRIBED, EVENT_SUMMARY_UPDATED, Event, get_event_bus
from .ffmpeg_capture import ffmpeg_list_avfoundation_devices, start_ffmpeg_segmenter
from .session_store import (
    Attendee,
    CoachingAlert,
    MeetingPrepContext,
    MeetingType,
    SessionPaths,
    SessionState,
    TalkingPoint,
    append_jsonl,
    append_transcript_text,
    init_session_dir,
    load_coaching_alerts,
    load_full_transcript,
    load_meeting_prep,
    load_state,
    load_transcript_since,
    resolve_session_paths,
    save_meeting_prep,
    save_state,
    write_summary,
)
from .summarize import update_running_summary
from .transcribe import transcribe_file_gemini


# Active sessions tracking
class AutoRecordRuntime:
    """Tracks the background automatic recording watcher."""

    def __init__(self) -> None:
        self.started_event_ids: dict[str, datetime] = {}
        self.last_checked_at: Optional[datetime] = None
        self.last_error: Optional[str] = None
        self.last_started_at: Optional[datetime] = None
        self.last_started_event_id: Optional[str] = None
        self.last_started_event_title: Optional[str] = None
        self.current_session_id: Optional[str] = None
        # A meeting we want to record but are holding back on because its
        # configured audio devices aren't connected yet. Retried every poll
        # until the devices appear or the meeting ends.
        self.pending_meeting: Optional["CalendarMeeting"] = None


class ActiveSession:
    """Tracks state for an active recording session."""

    def __init__(
        self,
        session_id: str,
        paths: SessionPaths,
        state: SessionState,
        device_index: str,  # Can be "0" or "0,1" for mixing multiple devices
    ):
        self.session_id = session_id
        self.paths = paths
        self.state = state
        self.device_index = device_index
        self.status = SessionStatus.CREATED
        self.started_at: Optional[datetime] = None
        self.stopped_at: Optional[datetime] = None
        self.ffmpeg_process: Optional[subprocess.Popen] = None
        self.processing_task: Optional[asyncio.Task] = None
        self.summary_minutes: int = 5
        self.keep_audio: bool = False
        self.language: Optional[str] = None
        self.transcribe_model: str = "gemini-3.5-flash"
        self.coaching_model: str = "gemini-3.5-flash"
        self.max_duration_seconds: int = 8 * 3600  # Default 8 hours
        self.inactivity_timeout_chunks: int = 10  # Consecutive inactive chunks before auto-stop
        self.inactivity_word_threshold: int = 5  # Words below which a chunk is "inactive"
        self._consecutive_inactive_chunks: int = 0
        self.capture_started_at: Optional[datetime] = None
        self.capture_restarts: int = 0


_active_sessions: dict[str, ActiveSession] = {}
_websocket_connections: dict[str, list[WebSocket]] = {}  # session_id -> websockets
_auto_record_runtime = AutoRecordRuntime()
_auto_record_task: Optional[asyncio.Task] = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan handler."""
    global _auto_record_task
    _auto_record_task = asyncio.create_task(_auto_record_loop())
    try:
        yield
    finally:
        if _auto_record_task:
            _auto_record_task.cancel()
            try:
                await _auto_record_task
            except asyncio.CancelledError:
                pass
    # Cleanup on shutdown
    for session in _active_sessions.values():
        if session.ffmpeg_process:
            _shutdown_ffmpeg(session.ffmpeg_process, sigint_timeout=5)
            session.ffmpeg_process = None


app = FastAPI(
    title="Live Transcription Coaching API",
    description="Real-time transcription with AI coaching",
    version="0.1.0",
    lifespan=lifespan,
)

# CORS for frontend
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # In production, restrict this
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ----- Helper Functions -----


def get_sessions_dir() -> Path:
    """Get the sessions directory."""
    # First check relative to cwd, then relative to package
    cwd_sessions = Path.cwd() / "sessions"
    if cwd_sessions.exists():
        return cwd_sessions

    # Fall back to project root (two levels up from this file)
    package_dir = Path(__file__).parent.parent.parent
    return package_dir / "sessions"


def get_session_by_id(session_id: str) -> tuple[SessionPaths, SessionState]:
    """Get session paths and state by ID."""
    sessions_dir = get_sessions_dir()
    session_dir = sessions_dir / session_id

    if not session_dir.exists():
        raise HTTPException(status_code=404, detail=f"Session {session_id} not found")

    paths = resolve_session_paths(session_dir)
    state = load_state(paths)

    if state is None:
        raise HTTPException(status_code=404, detail=f"Session {session_id} has no state")

    return paths, state


async def broadcast_to_session(session_id: str, message: dict[str, Any]) -> None:
    """Broadcast a message to all WebSocket connections for a session."""
    if session_id not in _websocket_connections:
        return

    dead_connections = []
    for ws in _websocket_connections[session_id]:
        try:
            await ws.send_json(message)
        except Exception:
            dead_connections.append(ws)

    # Clean up dead connections
    for ws in dead_connections:
        _websocket_connections[session_id].remove(ws)


# ----- Settings Endpoints -----


def get_settings_path() -> Path:
    """Get the app-wide settings file path."""
    return get_sessions_dir() / "app_settings.json"


def _settings_to_response(settings: StoredAppSettings) -> AppSettingsResponse:
    updated_at = None
    if settings.updated_at:
        try:
            updated_at = datetime.fromisoformat(settings.updated_at)
        except ValueError:
            updated_at = None

    return AppSettingsResponse(
        default_devices=[
            SavedAudioDevice(index=device.index, name=device.name)
            for device in settings.default_devices
        ],
        chunk_seconds=settings.chunk_seconds,
        summary_minutes=settings.summary_minutes,
        auto_record_enabled=settings.auto_record_enabled,
        auto_record_start_window_minutes=settings.auto_record_start_window_minutes,
        auto_record_join_grace_minutes=settings.auto_record_join_grace_minutes,
        auto_record_poll_seconds=settings.auto_record_poll_seconds,
        auto_record_require_meeting_link=settings.auto_record_require_meeting_link,
        auto_record_skip_private_events=settings.auto_record_skip_private_events,
        google_calendar_credentials_path=settings.google_calendar_credentials_path,
        updated_at=updated_at,
    )


@app.get("/api/settings", response_model=AppSettingsResponse)
def get_settings():
    """Get app-wide saved settings."""
    return _settings_to_response(load_app_settings(get_settings_path()))


@app.put("/api/settings", response_model=AppSettingsResponse)
def update_settings(request: AppSettingsUpdate):
    """Update app-wide saved settings."""
    settings = StoredAppSettings(
        default_devices=[
            StoredSavedAudioDevice(index=device.index, name=device.name)
            for device in request.default_devices
        ],
        chunk_seconds=request.chunk_seconds,
        summary_minutes=request.summary_minutes,
        auto_record_enabled=request.auto_record_enabled,
        auto_record_start_window_minutes=request.auto_record_start_window_minutes,
        auto_record_join_grace_minutes=request.auto_record_join_grace_minutes,
        auto_record_poll_seconds=request.auto_record_poll_seconds,
        auto_record_require_meeting_link=request.auto_record_require_meeting_link,
        auto_record_skip_private_events=request.auto_record_skip_private_events,
        google_calendar_credentials_path=request.google_calendar_credentials_path,
        updated_at=datetime.now().isoformat(timespec="seconds"),
    )
    return _settings_to_response(save_app_settings(get_settings_path(), settings))


@app.get("/api/auto-record/status", response_model=AutoRecordStatusResponse)
def get_auto_record_status():
    """Get automatic recording watcher status."""
    settings = load_app_settings(get_settings_path())
    return _auto_record_status(settings)


@app.post("/api/auto-record/check", response_model=AutoRecordStatusResponse)
async def check_auto_record_now():
    """Run one automatic recording calendar check immediately."""
    settings = load_app_settings(get_settings_path())
    await _run_auto_record_check(settings, allow_interactive_auth=True)
    return _auto_record_status(settings)


def _auto_record_status(settings: StoredAppSettings) -> AutoRecordStatusResponse:
    return AutoRecordStatusResponse(
        enabled=settings.auto_record_enabled,
        running=_auto_record_task is not None and not _auto_record_task.done(),
        last_checked_at=_auto_record_runtime.last_checked_at,
        last_error=_auto_record_runtime.last_error,
        last_started_at=_auto_record_runtime.last_started_at,
        last_started_event_id=_auto_record_runtime.last_started_event_id,
        last_started_event_title=_auto_record_runtime.last_started_event_title,
        current_session_id=_auto_record_runtime.current_session_id,
    )


async def _auto_record_loop() -> None:
    """Poll calendar settings and start sessions for meetings as they begin."""
    while True:
        try:
            settings = load_app_settings(get_settings_path())
            if settings.auto_record_enabled:
                await _run_auto_record_check(settings)
                sleep_seconds = settings.auto_record_poll_seconds
            else:
                sleep_seconds = 5
            await asyncio.sleep(sleep_seconds)
        except asyncio.CancelledError:
            raise
        except Exception as e:
            _auto_record_runtime.last_error = str(e)
            await asyncio.sleep(30)


async def _run_auto_record_check(
    settings: StoredAppSettings,
    *,
    allow_interactive_auth: bool = False,
) -> None:
    now = datetime.now()
    _auto_record_runtime.last_checked_at = now
    _auto_record_runtime.last_error = None
    _forget_old_started_events(now)
    _forget_ended_pending_meeting()

    if not settings.auto_record_enabled:
        return

    if _has_active_recording_session():
        return

    if not settings.default_devices:
        _auto_record_runtime.last_error = "Automatic recording needs saved default audio devices."
        return

    # 1. Resume a meeting we previously deferred because its audio devices
    #    weren't connected. We keep retrying it (even after it leaves the
    #    calendar's start window) until the devices appear or the meeting ends,
    #    so a late mic connection still gets recorded.
    pending = _auto_record_runtime.pending_meeting
    if pending is not None:
        if pending.event_id in _auto_record_runtime.started_event_ids:
            _auto_record_runtime.pending_meeting = None
        else:
            try:
                await _start_auto_recording_for_meeting(settings, pending)
                _auto_record_runtime.pending_meeting = None
            except DevicesUnavailableError as e:
                _auto_record_runtime.last_error = _waiting_for_devices_message(pending, e)
            except Exception as e:
                _auto_record_runtime.last_error = str(e)
            return

    # 2. Scan the calendar for a newly-eligible meeting to start.
    try:
        meetings = await asyncio.to_thread(
            fetch_google_calendar_meetings,
            settings,
            settings_dir=get_settings_path().parent,
            allow_interactive_auth=allow_interactive_auth,
        )
        for meeting in meetings:
            if meeting.event_id in _auto_record_runtime.started_event_ids:
                continue
            try:
                await _start_auto_recording_for_meeting(settings, meeting)
            except DevicesUnavailableError as e:
                # Hold the meeting and keep retrying on later polls instead of
                # dropping it once it falls out of the calendar window.
                _auto_record_runtime.pending_meeting = meeting
                _auto_record_runtime.last_error = _waiting_for_devices_message(meeting, e)
            return
    except Exception as e:
        _auto_record_runtime.last_error = str(e)


def _waiting_for_devices_message(
    meeting: CalendarMeeting, error: DevicesUnavailableError
) -> str:
    return (
        f"Waiting for audio devices to record '{meeting.title}': "
        f"{', '.join(error.missing)}. Will start automatically once they're connected."
    )


def _forget_ended_pending_meeting() -> None:
    pending = _auto_record_runtime.pending_meeting
    if pending is not None and pending.end <= datetime.now(timezone.utc):
        _auto_record_runtime.pending_meeting = None


def _forget_old_started_events(now: datetime) -> None:
    cutoff = now - timedelta(hours=12)
    _auto_record_runtime.started_event_ids = {
        event_id: started_at
        for event_id, started_at in _auto_record_runtime.started_event_ids.items()
        if started_at > cutoff
    }


def _has_active_recording_session() -> bool:
    return any(active.status == SessionStatus.RECORDING for active in _active_sessions.values())


class DevicesUnavailableError(RuntimeError):
    """Raised when one or more configured default audio devices are missing."""

    def __init__(self, missing: list[str]) -> None:
        self.missing = missing
        super().__init__(
            "Required audio devices are not available: "
            f"{', '.join(missing)}. Recording was not started to avoid a poor-quality capture."
        )


def _match_saved_devices(
    settings: StoredAppSettings,
) -> tuple[list[int], list[ConfiguredDeviceStatus], list[str]]:
    """Match the saved default devices against currently-attached audio inputs.

    Devices are matched strictly by name: AVFoundation indices shift as devices
    come and go, so a saved index can silently point at a different device
    (e.g. an iPhone Continuity mic taking the slot of disconnected AirPods).
    Returns the matched AVFoundation indices (in saved order), a per-device
    availability status, and the names of any configured devices that are not
    currently present.
    """
    devices = [
        device
        for device in ffmpeg_list_avfoundation_devices()
        if device.kind == "audio"
    ]
    by_name = {device.name: device for device in devices}

    matched_indices: list[int] = []
    statuses: list[ConfiguredDeviceStatus] = []
    missing: list[str] = []
    for saved_device in settings.default_devices:
        device = by_name.get(saved_device.name)
        if device is not None:
            if device.index not in matched_indices:
                matched_indices.append(device.index)
            statuses.append(
                ConfiguredDeviceStatus(
                    name=saved_device.name, index=device.index, available=True
                )
            )
        else:
            missing.append(saved_device.name)
            statuses.append(
                ConfiguredDeviceStatus(name=saved_device.name, index=None, available=False)
            )

    return matched_indices, statuses, missing


def _resolve_default_device_string(settings: StoredAppSettings) -> str:
    """Resolve the saved default devices to an ffmpeg device string.

    Requires every configured device to be present; if any is missing we refuse
    to record rather than capture a partial (and therefore poor) recording.
    """
    if not settings.default_devices:
        raise RuntimeError(
            "No default audio devices are configured. Set them in Settings before recording."
        )

    matched_indices, _, missing = _match_saved_devices(settings)
    if missing:
        raise DevicesUnavailableError(missing)

    return ",".join(str(index) for index in matched_indices)


async def _start_auto_recording_for_meeting(
    settings: StoredAppSettings,
    meeting: CalendarMeeting,
) -> None:
    device_index = await asyncio.to_thread(_resolve_default_device_string, settings)
    session = create_session(
        SessionCreate(
            device_index=device_index,
            chunk_seconds=settings.chunk_seconds,
            summary_minutes=settings.summary_minutes,
        )
    )

    paths, _ = get_session_by_id(session.id)
    save_meeting_prep(paths, _meeting_to_prep(meeting))
    if session.id in _active_sessions:
        _active_sessions[session.id].status = SessionStatus.PREPARED

    await start_session(session.id)

    started_at = datetime.now()
    _auto_record_runtime.started_event_ids[meeting.event_id] = started_at
    _auto_record_runtime.last_started_at = started_at
    _auto_record_runtime.last_started_event_id = meeting.event_id
    _auto_record_runtime.last_started_event_title = meeting.title
    _auto_record_runtime.current_session_id = session.id


def _meeting_to_prep(meeting: CalendarMeeting) -> MeetingPrepContext:
    context_lines = [
        f"Calendar event: {meeting.title}",
        f"Start: {meeting.start.isoformat()}",
    ]
    if meeting.meeting_url:
        context_lines.append(f"Meeting URL: {meeting.meeting_url}")

    return MeetingPrepContext(
        meeting_type=MeetingType.INTERNAL_MEETING,
        attendees=[Attendee(name=attendee) for attendee in meeting.attendees],
        objectives=[f"Attend {meeting.title}"],
        additional_context="\n".join(context_lines),
    )


# ----- Device Endpoints -----


@app.get("/api/devices", response_model=DeviceListResponse)
def list_devices():
    """List available audio devices."""
    try:
        devices = ffmpeg_list_avfoundation_devices()
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to list devices: {e}")

    device_list = [
        DeviceInfo(index=d.index, name=d.name, type=d.kind) for d in devices
    ]

    return DeviceListResponse(devices=device_list)


@app.get("/api/devices/status", response_model=DeviceStatusResponse)
def get_device_status():
    """Report whether the saved default audio devices are currently available."""
    settings = load_app_settings(get_settings_path())
    try:
        _, statuses, missing = _match_saved_devices(settings)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to list devices: {e}")

    has_defaults = bool(settings.default_devices)
    return DeviceStatusResponse(
        configured=statuses,
        missing=missing,
        all_available=has_defaults and not missing,
        has_defaults=has_defaults,
    )


# ----- Session Endpoints -----


@app.get("/api/sessions", response_model=SessionListResponse)
def list_sessions():
    """List all sessions."""
    sessions_dir = get_sessions_dir()
    if not sessions_dir.exists():
        return SessionListResponse(sessions=[])

    sessions = []
    for session_dir in sorted(sessions_dir.iterdir(), reverse=True):
        if not session_dir.is_dir():
            continue

        paths = resolve_session_paths(session_dir)
        state = load_state(paths)
        if state is None:
            continue

        session_id = session_dir.name
        active = _active_sessions.get(session_id)

        # Determine status
        if active:
            status = active.status
            started_at = active.started_at
            stopped_at = active.stopped_at
        else:
            status = SessionStatus.STOPPED
            started_at = None
            stopped_at = None

        # Check if meeting prep exists
        prep = load_meeting_prep(paths)
        prep_response = None
        if prep:
            prep_response = _prep_to_response(prep)

        sessions.append(
            SessionResponse(
                id=session_id,
                status=status,
                created_at=datetime.fromisoformat(state.created_at),
                started_at=started_at,
                stopped_at=stopped_at,
                chunk_seconds=state.chunk_seconds,
                summary_minutes=5,  # Default
                chunks_processed=state.last_processed_index + 1,
                meeting_prep=prep_response,
            )
        )

    return SessionListResponse(sessions=sessions)


@app.post("/api/sessions", response_model=SessionResponse)
def create_session(request: SessionCreate):
    """Create a new transcription session."""
    # Resolve the audio devices to use. Device selection lives in Settings, so
    # unless an explicit device string is supplied we always use the saved
    # defaults (matched by name) and refuse if any required device is missing.
    device_index = request.device_index
    if not device_index:
        settings = load_app_settings(get_settings_path())
        try:
            device_index = _resolve_default_device_string(settings)
        except RuntimeError as e:
            raise HTTPException(status_code=409, detail=str(e))

    # Create session directory with timestamp
    timestamp = datetime.now().strftime("%Y-%m-%d_%H%M%S")
    sessions_dir = get_sessions_dir()
    session_dir = sessions_dir / timestamp

    paths = resolve_session_paths(session_dir)
    init_session_dir(paths)

    state = SessionState.new(chunk_seconds=request.chunk_seconds)
    save_state(paths, state)

    # Create active session tracker
    active = ActiveSession(
        session_id=timestamp,
        paths=paths,
        state=state,
        device_index=device_index,
    )
    active.summary_minutes = request.summary_minutes
    active.keep_audio = request.keep_audio
    active.language = request.language
    active.max_duration_seconds = int(request.max_duration_hours * 3600)
    active.inactivity_timeout_chunks = int(
        (request.inactivity_timeout_minutes * 60) / request.chunk_seconds
    )
    active.inactivity_word_threshold = request.inactivity_word_threshold
    active.status = SessionStatus.CREATED

    _active_sessions[timestamp] = active

    return SessionResponse(
        id=timestamp,
        status=SessionStatus.CREATED,
        created_at=datetime.fromisoformat(state.created_at),
        chunk_seconds=state.chunk_seconds,
        summary_minutes=request.summary_minutes,
    )


@app.get("/api/sessions/{session_id}", response_model=SessionResponse)
def get_session(session_id: str):
    """Get session details."""
    paths, state = get_session_by_id(session_id)
    active = _active_sessions.get(session_id)

    status = active.status if active else SessionStatus.STOPPED
    started_at = active.started_at if active else None
    stopped_at = active.stopped_at if active else None

    prep = load_meeting_prep(paths)
    prep_response = _prep_to_response(prep) if prep else None

    return SessionResponse(
        id=session_id,
        status=status,
        created_at=datetime.fromisoformat(state.created_at),
        started_at=started_at,
        stopped_at=stopped_at,
        chunk_seconds=state.chunk_seconds,
        summary_minutes=active.summary_minutes if active else 5,
        chunks_processed=state.last_processed_index + 1,
        meeting_prep=prep_response,
    )


def _prep_to_response(prep: MeetingPrepContext) -> MeetingPrepResponse:
    """Convert MeetingPrepContext to API response model."""
    from .api_models import AttendeeResponse, MeetingPrepResponse, TalkingPointResponse
    from .api_models import MeetingType as APIMeetingType

    return MeetingPrepResponse(
        meeting_type=APIMeetingType(prep.meeting_type.value),
        attendees=[
            AttendeeResponse(
                name=a.name, role=a.role, company=a.company, notes=a.notes
            )
            for a in prep.attendees
        ],
        objectives=prep.objectives,
        talking_points=[
            TalkingPointResponse(
                topic=tp.topic,
                priority=tp.priority,
                notes=tp.notes,
                mentioned=tp.mentioned,
                mentioned_at=datetime.fromisoformat(tp.mentioned_at) if tp.mentioned_at else None,
            )
            for tp in prep.talking_points
        ],
        competitors=prep.competitors,
        custom_reminders=prep.custom_reminders,
        pricing_notes=prep.pricing_notes,
        discount_authority=prep.discount_authority,
        additional_context=prep.additional_context,
    )


# ----- Meeting Prep Endpoints -----


@app.post("/api/sessions/{session_id}/prep", response_model=MeetingPrepResponse)
def submit_meeting_prep(session_id: str, request: MeetingPrepCreate):
    """Submit meeting prep context for a session."""
    paths, state = get_session_by_id(session_id)

    # Convert API model to domain model
    prep = MeetingPrepContext(
        meeting_type=MeetingType(request.meeting_type.value),
        attendees=[
            Attendee(name=a.name, role=a.role, company=a.company, notes=a.notes)
            for a in request.attendees
        ],
        objectives=request.objectives,
        talking_points=[
            TalkingPoint(topic=tp.topic, priority=tp.priority, notes=tp.notes)
            for tp in request.talking_points
        ],
        competitors=request.competitors,
        custom_reminders=request.custom_reminders,
        pricing_notes=request.pricing_notes,
        discount_authority=request.discount_authority,
        additional_context=request.additional_context,
    )

    save_meeting_prep(paths, prep)

    # Update session status
    if session_id in _active_sessions:
        _active_sessions[session_id].status = SessionStatus.PREPARED

    return _prep_to_response(prep)


@app.get("/api/sessions/{session_id}/prep", response_model=MeetingPrepResponse)
def get_meeting_prep(session_id: str):
    """Get meeting prep for a session."""
    paths, _ = get_session_by_id(session_id)
    prep = load_meeting_prep(paths)

    if prep is None:
        raise HTTPException(status_code=404, detail="No meeting prep for this session")

    return _prep_to_response(prep)


# ----- Recording Control Endpoints -----


@app.post("/api/sessions/{session_id}/start", response_model=SessionResponse)
async def start_session(session_id: str):
    """Start recording for a session."""
    if session_id not in _active_sessions:
        # Try to load existing session
        paths, state = get_session_by_id(session_id)
        raise HTTPException(
            status_code=400,
            detail="Session not active. Create a new session to start recording.",
        )

    active = _active_sessions[session_id]

    if active.status == SessionStatus.RECORDING:
        raise HTTPException(status_code=400, detail="Session already recording")

    # Start ffmpeg
    try:
        ffmpeg_proc = start_ffmpeg_segmenter(
            device=active.device_index,
            chunk_seconds=active.state.chunk_seconds,
            output_pattern=active.paths.chunks_dir / "out%05d.wav",
            stderr_path=active.paths.ffmpeg_log,
            loglevel="warning",
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to start recording: {e}")

    active.ffmpeg_process = ffmpeg_proc
    active.started_at = datetime.now()
    active.capture_started_at = active.started_at
    active.capture_restarts = 0
    active.status = SessionStatus.RECORDING

    await asyncio.sleep(0.5)
    if ffmpeg_proc.poll() is not None:
        active.ffmpeg_process = None
        active.stopped_at = datetime.now()
        active.status = SessionStatus.STOPPED
        detail = _recording_failure_message(
            active,
            "Recording process exited immediately.",
        )
        if _auto_record_runtime.current_session_id == active.session_id:
            _auto_record_runtime.last_error = detail
        raise HTTPException(status_code=500, detail=detail)

    # Start processing task
    active.processing_task = asyncio.create_task(
        _process_chunks(active)
    )

    return get_session(session_id)


@app.post("/api/sessions/{session_id}/stop", response_model=SessionResponse)
async def stop_session(session_id: str):
    """Stop recording for a session."""
    if session_id not in _active_sessions:
        raise HTTPException(status_code=404, detail="Session not active")

    active = _active_sessions[session_id]

    if active.status != SessionStatus.RECORDING:
        raise HTTPException(status_code=400, detail="Session not recording")

    # Stop ffmpeg
    if active.ffmpeg_process:
        await asyncio.to_thread(_shutdown_ffmpeg, active.ffmpeg_process)
        active.ffmpeg_process = None

    # Cancel processing task
    if active.processing_task:
        active.processing_task.cancel()
        try:
            await active.processing_task
        except asyncio.CancelledError:
            pass

    active.stopped_at = datetime.now()
    active.status = SessionStatus.STOPPED

    # Run final summary
    await _run_summary(active, force=True)

    return get_session(session_id)


def _is_chunk_inactive(text: str, word_threshold: int) -> bool:
    """Check if a transcribed chunk represents silence or sparse conversation.

    Returns True if the chunk is effectively silent/inactive:
    - Explicit silence markers like "(silence)"
    - Very few meaningful words (below threshold)
    """
    stripped = text.strip()
    if not stripped:
        return True

    # Check for silence markers
    lower = stripped.lower()
    if lower in ("(silence)", "[silence]", "silence", "(no speech)", "(inaudible)"):
        return True

    # Count meaningful words (strip speaker labels like [Speaker 1])
    clean = re.sub(r"\[Speaker\s*\d+\]", "", stripped)
    # Also strip common filler-only chunks
    clean = re.sub(r"[^\w\s]", "", clean)  # Remove punctuation
    words = [w for w in clean.split() if len(w) > 1]  # Skip single-letter fragments

    return len(words) < word_threshold


_MAX_CAPTURE_RESTARTS = 3


def _shutdown_ffmpeg(process: subprocess.Popen, *, sigint_timeout: float = 10.0) -> None:
    """Stop an ffmpeg capture, escalating SIGINT -> SIGTERM -> SIGKILL.

    A capture blocked on a stalled avfoundation input can ignore SIGINT (and
    sometimes SIGTERM), so keep escalating until the process is actually gone
    rather than letting a TimeoutExpired propagate and leave the session stuck.
    """
    if process.poll() is not None:
        return
    process.send_signal(signal.SIGINT)
    try:
        process.wait(timeout=sigint_timeout)
        return
    except subprocess.TimeoutExpired:
        pass
    process.terminate()
    try:
        process.wait(timeout=5)
        return
    except subprocess.TimeoutExpired:
        pass
    process.kill()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        # SIGKILL was delivered; the kernel will reap it. Nothing more we can do.
        pass


def _capture_stall_timeout_seconds(chunk_seconds: int) -> int:
    return max(2 * chunk_seconds + 15, 60)


def _latest_chunk_activity(chunks_dir: Path) -> Optional[float]:
    """Return the most recent mtime of any chunk file, or None if there are none."""
    latest: Optional[float] = None
    for path in chunks_dir.glob("*.wav"):
        try:
            mtime = path.stat().st_mtime
        except OSError:
            continue
        if latest is None or mtime > latest:
            latest = mtime
    return latest


def _capture_is_stalled(
    chunks_dir: Path,
    capture_started_at: datetime,
    chunk_seconds: int,
    now: Optional[float] = None,
) -> bool:
    """Whether ffmpeg has stopped writing audio even though it is still running.

    ffmpeg continuously updates the in-progress segment file, so if neither it
    nor any other chunk has been touched for well over a chunk interval, the
    capture is wedged (e.g. an avfoundation input device went away).
    """
    if now is None:
        now = time.time()
    baseline = _latest_chunk_activity(chunks_dir) or 0.0
    baseline = max(baseline, capture_started_at.timestamp())
    return now - baseline >= _capture_stall_timeout_seconds(chunk_seconds)


def _next_segment_number(chunks_dir: Path, last_processed_index: int) -> int:
    from .chunk_watcher import max_chunk_index

    return max(max_chunk_index(chunks_dir), last_processed_index) + 1


def _read_ffmpeg_log_tail(paths: SessionPaths, max_chars: int = 1200) -> str:
    if not paths.ffmpeg_log.exists():
        return ""
    try:
        content = paths.ffmpeg_log.read_text(encoding="utf-8", errors="replace").strip()
    except OSError:
        return ""
    if len(content) <= max_chars:
        return content
    return content[-max_chars:]


def _recording_failure_message(active: ActiveSession, prefix: str) -> str:
    details = [
        prefix,
        f"Audio devices: {active.device_index}.",
    ]
    log_tail = _read_ffmpeg_log_tail(active.paths)
    if log_tail:
        details.append(f"ffmpeg: {log_tail}")
    else:
        details.append("ffmpeg produced no diagnostic output.")
    return " ".join(details)


async def _stop_recording_with_error(
    active: ActiveSession,
    *,
    reason: str,
    message: str,
) -> None:
    if active.ffmpeg_process:
        await asyncio.to_thread(_shutdown_ffmpeg, active.ffmpeg_process)
    active.ffmpeg_process = None
    active.stopped_at = datetime.now()
    active.status = SessionStatus.STOPPED

    if _auto_record_runtime.current_session_id == active.session_id:
        _auto_record_runtime.last_error = message

    await broadcast_to_session(
        active.session_id,
        {
            "type": "session_status",
            "data": {
                "status": "stopped",
                "reason": reason,
                "message": message,
            },
        },
    )


async def _recover_stalled_capture(active: ActiveSession) -> None:
    """Kill a wedged ffmpeg capture and restart it, or stop the session.

    Restarts continue segment numbering after the highest existing chunk so the
    stalled partial segment is still transcribed once a newer one appears. After
    _MAX_CAPTURE_RESTARTS consecutive stalls the session is stopped with an
    error instead of looping on a dead input forever.
    """
    stall_timeout = _capture_stall_timeout_seconds(active.state.chunk_seconds)
    print(
        f"[server] Capture stalled for session {active.session_id}: "
        f"no audio written for {stall_timeout}s "
        f"(restart {active.capture_restarts + 1}/{_MAX_CAPTURE_RESTARTS})"
    )

    if active.ffmpeg_process:
        await asyncio.to_thread(_shutdown_ffmpeg, active.ffmpeg_process)
        active.ffmpeg_process = None

    async def _give_up(message: str) -> None:
        await _stop_recording_with_error(
            active, reason="recording_stalled", message=message
        )
        if active.state.last_processed_index >= 0:
            await _run_summary(active, force=True)

    if active.capture_restarts >= _MAX_CAPTURE_RESTARTS:
        await _give_up(
            _recording_failure_message(
                active,
                (
                    f"Recording stalled {active.capture_restarts + 1} times "
                    f"(no audio written for {stall_timeout}s each time); giving up."
                ),
            )
        )
        return

    active.capture_restarts += 1
    next_segment = _next_segment_number(
        active.paths.chunks_dir, active.state.last_processed_index
    )
    try:
        active.ffmpeg_process = await asyncio.to_thread(
            lambda: start_ffmpeg_segmenter(
                device=active.device_index,
                chunk_seconds=active.state.chunk_seconds,
                output_pattern=active.paths.chunks_dir / "out%05d.wav",
                stderr_path=active.paths.ffmpeg_log,
                loglevel="warning",
                segment_start_number=next_segment,
            )
        )
    except Exception as e:
        await _give_up(
            _recording_failure_message(
                active, f"Could not restart stalled recording: {e}."
            )
        )
        return

    active.capture_started_at = datetime.now()
    print(
        f"[server] Restarted capture for session {active.session_id} "
        f"at segment {next_segment}"
    )


async def _process_chunks(active: ActiveSession) -> None:
    """Background task to process audio chunks as they're created."""
    from .chunk_watcher import find_next_completed_chunk, wait_for_file_stable

    event_bus = get_event_bus()
    coaching_engine = get_coaching_engine(active.coaching_model)
    last_summary_index = active.state.last_summarized_index
    chunks_per_summary = (active.summary_minutes * 60) // active.state.chunk_seconds

    while active.status == SessionStatus.RECORDING:
        try:
            if active.ffmpeg_process and active.ffmpeg_process.poll() is not None:
                message = _recording_failure_message(
                    active,
                    "Recording process exited before any audio could be processed.",
                )
                await _stop_recording_with_error(
                    active,
                    reason="recording_process_exited",
                    message=message,
                )
                return

            if active.started_at and active.state.last_processed_index < 0:
                elapsed = (datetime.now() - active.started_at).total_seconds()
                first_chunk_timeout = max(active.state.chunk_seconds + 15, 45)
                has_audio_files = any(active.paths.chunks_dir.glob("*.wav"))
                if elapsed >= first_chunk_timeout and not has_audio_files:
                    message = _recording_failure_message(
                        active,
                        (
                            "Recording started, but no audio chunk was written "
                            f"after {int(elapsed)} seconds."
                        ),
                    )
                    await _stop_recording_with_error(
                        active,
                        reason="no_audio_chunks_written",
                        message=message,
                    )
                    return

            # Detect a wedged capture: ffmpeg still running but no chunk file
            # has been touched for well over a chunk interval (e.g. an
            # avfoundation input went away mid-recording). Restart the capture
            # so the rest of the meeting is still recorded; give up after
            # repeated stalls.
            if (
                active.ffmpeg_process
                and active.capture_started_at
                and _capture_is_stalled(
                    active.paths.chunks_dir,
                    active.capture_started_at,
                    active.state.chunk_seconds,
                )
            ):
                await _recover_stalled_capture(active)
                if active.status != SessionStatus.RECORDING:
                    return
                continue

            # Check max duration
            if active.max_duration_seconds and active.started_at:
                elapsed = (datetime.now() - active.started_at).total_seconds()
                if elapsed >= active.max_duration_seconds:
                    hours = active.max_duration_seconds / 3600
                    print(f"[server] Auto-stopping session {active.session_id}: {hours}h limit reached")
                    if active.ffmpeg_process:
                        await asyncio.to_thread(_shutdown_ffmpeg, active.ffmpeg_process)
                        active.ffmpeg_process = None
                    active.stopped_at = datetime.now()
                    active.status = SessionStatus.STOPPED
                    await broadcast_to_session(
                        active.session_id,
                        {
                            "type": "session_status",
                            "data": {
                                "status": "stopped",
                                "reason": "max_duration_reached",
                                "message": f"Session auto-stopped after {hours:.0f}h limit.",
                            },
                        },
                    )
                    await _run_summary(active, force=True)
                    return

            # Look for next chunk
            chunk = find_next_completed_chunk(
                active.paths.chunks_dir,
                after_index=active.state.last_processed_index,
            )

            if chunk is None:
                await asyncio.sleep(0.5)
                continue

            # Wait for file to be stable
            await asyncio.to_thread(wait_for_file_stable, chunk.path)

            # Transcribe with Gemini (includes diarization)
            transcript_result = await asyncio.to_thread(
                transcribe_file_gemini,
                chunk.path,
                model=active.transcribe_model,
                language=active.language,
                diarize=True,
            )

            text = transcript_result.text
            segments = transcript_result.segments

            # Get chunk index from the ChunkFile
            chunk_index = chunk.index

            # Persist transcript (with speaker labels if available)
            if segments:
                # Format with speaker labels for the text file
                formatted_text = " ".join(f"[{s.speaker}] {s.text}" for s in segments)
            else:
                formatted_text = text

            append_transcript_text(
                active.paths,
                chunk_index=chunk_index,
                chunk_seconds=active.state.chunk_seconds,
                text=formatted_text,
            )

            # Persist to JSONL with full segment data
            append_jsonl(
                active.paths,
                {
                    "index": chunk_index,
                    "chunk_file": str(chunk.path.name),
                    "text": text,
                    "segments": [s.to_dict() for s in segments],
                    "model": active.transcribe_model,
                    "language": active.language,
                    "recorded_at": datetime.now().isoformat(),
                },
            )

            # Update state
            active.state.last_processed_index = chunk_index
            save_state(active.paths, active.state)

            # Broadcast transcript chunk with segments
            from .session_store import format_hhmmss

            timestamp = format_hhmmss(chunk_index * active.state.chunk_seconds)
            await broadcast_to_session(
                active.session_id,
                {
                    "type": "transcript_chunk",
                    "data": {
                        "index": chunk_index,
                        "text": text,
                        "segments": [s.to_dict() for s in segments],
                        "timestamp": timestamp,
                        "recorded_at": datetime.now().isoformat(),
                    },
                },
            )

            # Publish event
            await event_bus.publish(
                Event(
                    type=EVENT_CHUNK_TRANSCRIBED,
                    data={"index": chunk_index, "text": text, "segments": [s.to_dict() for s in segments]},
                    session_id=active.session_id,
                )
            )

            # Run coaching analysis (use formatted text with speakers for context)
            prep = load_meeting_prep(active.paths)
            coaching_result = await coaching_engine.analyze_chunk(
                active.paths,
                prep,
                formatted_text,
                active.session_id,
            )

            # Broadcast coaching alerts
            for alert in coaching_result.alerts:
                await broadcast_to_session(
                    active.session_id,
                    {
                        "type": "coaching_alert",
                        "data": alert.to_dict(),
                    },
                )

            # Track inactivity for meeting-end detection
            if active.inactivity_timeout_chunks > 0:
                if _is_chunk_inactive(text, active.inactivity_word_threshold):
                    active._consecutive_inactive_chunks += 1
                    inactive_seconds = active._consecutive_inactive_chunks * active.state.chunk_seconds
                    inactive_minutes = inactive_seconds / 60
                    print(
                        f"[server] Inactive chunk #{active._consecutive_inactive_chunks} "
                        f"({inactive_minutes:.1f}m) - threshold: {active.inactivity_timeout_chunks} chunks"
                    )

                    if active._consecutive_inactive_chunks >= active.inactivity_timeout_chunks:
                        print(
                            f"[server] Auto-stopping session {active.session_id}: "
                            f"meeting appears ended ({inactive_minutes:.0f}m of inactivity)"
                        )
                        if active.ffmpeg_process:
                            await asyncio.to_thread(_shutdown_ffmpeg, active.ffmpeg_process)
                            active.ffmpeg_process = None
                        active.stopped_at = datetime.now()
                        active.status = SessionStatus.STOPPED
                        await broadcast_to_session(
                            active.session_id,
                            {
                                "type": "session_status",
                                "data": {
                                    "status": "stopped",
                                    "reason": "meeting_ended_inactivity",
                                    "message": (
                                        f"Session auto-stopped: no meaningful conversation "
                                        f"detected for {inactive_minutes:.0f} minutes."
                                    ),
                                },
                            },
                        )
                        await _run_summary(active, force=True)
                        return
                else:
                    # Reset counter on any meaningful conversation
                    if active._consecutive_inactive_chunks > 0:
                        print(
                            f"[server] Inactivity counter reset (was {active._consecutive_inactive_chunks})"
                        )
                    active._consecutive_inactive_chunks = 0

            # Check if we should run summary
            chunks_since_summary = chunk_index - last_summary_index
            if chunks_since_summary >= chunks_per_summary:
                await _run_summary(active)
                last_summary_index = chunk_index

            # Clean up audio file if not keeping
            if not active.keep_audio:
                chunk.path.unlink(missing_ok=True)

        except asyncio.CancelledError:
            break
        except Exception as e:
            print(f"[server] Error processing chunk: {e}")
            await asyncio.sleep(1)


async def _run_summary(active: ActiveSession, force: bool = False) -> None:
    """Run incremental summary update."""
    event_bus = get_event_bus()

    # Get new transcript since last summary
    chunks = load_transcript_since(
        active.paths, after_index=active.state.last_summarized_index
    )

    if not chunks and not force:
        return

    new_text = "\n".join(chunk.text for chunk in chunks)

    # Run summary
    try:
        updated_summary = await asyncio.to_thread(
            update_running_summary,
            previous_summary=active.state.summary,
            new_transcript=new_text,
            model="gemini-3.5-flash",
        )

        active.state.summary = updated_summary
        active.state.last_summarized_index = active.state.last_processed_index
        save_state(active.paths, active.state)
        write_summary(active.paths, summary=updated_summary)

        # Broadcast summary update
        await broadcast_to_session(
            active.session_id,
            {
                "type": "summary_update",
                "data": {
                    "summary": updated_summary,
                    "last_updated": datetime.now().isoformat(),
                },
            },
        )

        # Publish event
        await event_bus.publish(
            Event(
                type=EVENT_SUMMARY_UPDATED,
                data={"summary": updated_summary},
                session_id=active.session_id,
            )
        )

    except Exception as e:
        print(f"[server] Error running summary: {e}")


# ----- Transcript Endpoints -----


@app.get("/api/sessions/{session_id}/transcript", response_model=TranscriptResponse)
def get_transcript(session_id: str):
    """Get transcript for a session."""
    paths, state = get_session_by_id(session_id)

    full_text = load_full_transcript(paths)
    chunks_data = load_transcript_since(paths, after_index=-1)

    from .session_store import format_hhmmss
    from .api_models import TranscriptSegment as APITranscriptSegment

    chunks = [
        TranscriptChunk(
            index=chunk.index,
            text=chunk.text,
            timestamp=format_hhmmss(chunk.index * state.chunk_seconds),
            recorded_at=datetime.fromisoformat(chunk.recorded_at) if chunk.recorded_at else datetime.now(),
            segments=[
                APITranscriptSegment(
                    speaker=seg.speaker,
                    text=seg.text,
                    start=seg.start_time,
                    end=seg.end_time,
                )
                for seg in chunk.segments
            ],
        )
        for chunk in chunks_data
    ]

    return TranscriptResponse(
        session_id=session_id,
        chunks=chunks,
        full_text=full_text,
    )


@app.get("/api/sessions/{session_id}/summary", response_model=SummaryResponse)
def get_summary(session_id: str):
    """Get summary for a session."""
    paths, state = get_session_by_id(session_id)

    return SummaryResponse(
        session_id=session_id,
        summary=state.summary,
    )


@app.post("/api/sessions/{session_id}/summary/regenerate", response_model=SummaryResponse)
def regenerate_summary(session_id: str):
    """Regenerate summary from transcript (useful if summary was truncated)."""
    paths, state = get_session_by_id(session_id)

    # Load all transcript chunks
    chunks = load_transcript_since(paths, after_index=-1)
    if not chunks:
        raise HTTPException(status_code=400, detail="No transcript chunks found")

    # Combine all transcript text
    full_transcript = "\n".join(chunk.text for chunk in chunks)

    # Generate summary from scratch
    try:
        summary = update_running_summary(
            previous_summary="",
            new_transcript=full_transcript,
            model="gemini-3.5-flash",
        )
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Summary generation failed: {exc}")

    # Save the new summary
    write_summary(paths, summary=summary)

    # Update state
    state.summary = summary
    state.last_summarized_index = chunks[-1].index
    save_state(paths, state)

    return SummaryResponse(
        session_id=session_id,
        summary=summary,
    )


@app.get("/api/sessions/{session_id}/coaching", response_model=CoachingHistoryResponse)
def get_coaching_history(session_id: str):
    """Get coaching alert history for a session."""
    paths, _ = get_session_by_id(session_id)
    alerts = load_coaching_alerts(paths)

    from .api_models import AlertType as APIAlertType
    from .api_models import CoachingAlertResponse

    return CoachingHistoryResponse(
        session_id=session_id,
        alerts=[
            CoachingAlertResponse(
                id=a.id,
                alert_type=APIAlertType(a.alert_type.value),
                content=a.content,
                suggestion=a.suggestion,
                timestamp=datetime.fromisoformat(a.timestamp),
                dismissed=a.dismissed,
                metadata=a.metadata,
            )
            for a in alerts
        ],
    )


# ----- Chat Endpoint -----


class ChatMessageHistory(BaseModel):
    """A single message in the chat history."""

    role: str  # 'user' or 'assistant'
    content: str


class ChatRequest(BaseModel):
    """Request model for chat messages."""

    message: str
    history: list[ChatMessageHistory] = Field(default_factory=list)


class ChatResponse(BaseModel):
    """Response model for chat messages."""

    response: str


@app.post("/api/sessions/{session_id}/chat", response_model=ChatResponse)
async def chat_with_session(session_id: str, request: ChatRequest):
    """Chat about the session's conversation content."""
    paths, state = get_session_by_id(session_id)

    # Load the full transcript
    full_transcript = load_full_transcript(paths)
    if not full_transcript.strip():
        return ChatResponse(response="No transcript available yet. Start recording first.")

    # Load summary if available
    summary = state.summary or ""

    # Build context for the AI
    system_context = f"""You are a helpful assistant that answers questions about a conversation/meeting transcript.

Here is the transcript of the conversation:

{full_transcript}

{f"Here is a summary of the conversation so far:{chr(10)}{summary}" if summary else ""}

Answer the user's question based on the transcript content. Be concise and factual. If something wasn't discussed in the transcript, say so.
"""

    # Build conversation with history
    from google import genai
    from google.genai import types

    client = genai.Client()

    # Build messages
    messages = [{"role": "user", "parts": [{"text": system_context + "\n\nUser: " + request.message}]}]

    # Add conversation history context if present
    if request.history:
        history_text = "\n".join([f"{'User' if m.role == 'user' else 'Assistant'}: {m.content}" for m in request.history[-5:]])
        messages = [{"role": "user", "parts": [{"text": system_context + f"\n\nPrevious conversation:\n{history_text}\n\nUser: {request.message}"}]}]

    try:
        response = await asyncio.to_thread(
            lambda: client.models.generate_content(
                model="gemini-3.5-flash",
                contents=messages,
                config=types.GenerateContentConfig(
                    thinking_config=types.ThinkingConfig(thinkingBudget=8192),
                    max_output_tokens=2000,
                ),
            )
        )

        return ChatResponse(response=response.text or "Sorry, I couldn't generate a response.")
    except Exception as e:
        print(f"[server] Chat error: {e}")
        return ChatResponse(response=f"Error: {str(e)}")


# ----- WebSocket Endpoint -----


@app.websocket("/ws/sessions/{session_id}")
async def websocket_endpoint(websocket: WebSocket, session_id: str):
    """WebSocket endpoint for real-time updates."""
    await websocket.accept()

    # Register connection
    if session_id not in _websocket_connections:
        _websocket_connections[session_id] = []
    _websocket_connections[session_id].append(websocket)

    try:
        # Send current state
        try:
            paths, state = get_session_by_id(session_id)
            active = _active_sessions.get(session_id)

            await websocket.send_json({
                "type": "session_status",
                "data": {
                    "status": active.status.value if active else "stopped",
                    "chunks_processed": state.last_processed_index + 1,
                },
            })
        except HTTPException:
            pass  # Session might not exist yet

        # Keep connection alive and handle client messages
        while True:
            try:
                data = await websocket.receive_json()
                # Handle client commands if needed
                if data.get("type") == "ping":
                    await websocket.send_json({"type": "pong"})
            except WebSocketDisconnect:
                break

    finally:
        # Unregister connection
        if session_id in _websocket_connections:
            try:
                _websocket_connections[session_id].remove(websocket)
            except ValueError:
                pass


# ----- Static Files (for frontend) -----


def mount_static_files(static_dir: Path) -> None:
    """Mount static files for serving the frontend."""
    if static_dir.exists():
        app.mount("/", StaticFiles(directory=static_dir, html=True), name="static")


# ----- Run Server -----


def run_server(
    host: str = "127.0.0.1",
    port: int = 8765,
    static_dir: Optional[Path] = None,
) -> None:
    """Run the FastAPI server."""
    import uvicorn

    if static_dir:
        mount_static_files(static_dir)

    uvicorn.run(app, host=host, port=port)
