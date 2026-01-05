"""
FastAPI server with REST and WebSocket endpoints for real-time transcription coaching.
"""

from __future__ import annotations

import asyncio
import json
import os
import signal
import subprocess
from contextlib import asynccontextmanager
from datetime import datetime
from pathlib import Path
from typing import Any, Optional

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

from .api_models import (
    CoachingHistoryResponse,
    DeviceInfo,
    DeviceListResponse,
    MeetingPrepCreate,
    MeetingPrepResponse,
    SessionCreate,
    SessionListResponse,
    SessionResponse,
    SessionStatus,
    SummaryResponse,
    TalkingPointResponse,
    TranscriptChunk,
    TranscriptResponse,
)
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
        self.transcribe_model: str = "gemini-3-flash-preview"
        self.coaching_model: str = "gemini-3-flash-preview"


_active_sessions: dict[str, ActiveSession] = {}
_websocket_connections: dict[str, list[WebSocket]] = {}  # session_id -> websockets


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan handler."""
    yield
    # Cleanup on shutdown
    for session in _active_sessions.values():
        if session.ffmpeg_process:
            session.ffmpeg_process.send_signal(signal.SIGINT)
            session.ffmpeg_process.wait(timeout=5)


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
    return Path.cwd() / "sessions"


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
        device_index=request.device_index,
    )
    active.summary_minutes = request.summary_minutes
    active.keep_audio = request.keep_audio
    active.language = request.language
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
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to start recording: {e}")

    active.ffmpeg_process = ffmpeg_proc
    active.started_at = datetime.now()
    active.status = SessionStatus.RECORDING

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
        active.ffmpeg_process.send_signal(signal.SIGINT)
        active.ffmpeg_process.wait(timeout=10)
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


async def _process_chunks(active: ActiveSession) -> None:
    """Background task to process audio chunks as they're created."""
    from .chunk_watcher import find_next_completed_chunk, wait_for_file_stable

    event_bus = get_event_bus()
    coaching_engine = get_coaching_engine(active.coaching_model)
    last_summary_index = active.state.last_summarized_index
    chunks_per_summary = (active.summary_minutes * 60) // active.state.chunk_seconds

    while active.status == SessionStatus.RECORDING:
        try:
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

    new_text = "\n".join(text for _, text in chunks)

    # Run summary
    try:
        updated_summary = await asyncio.to_thread(
            update_running_summary,
            previous_summary=active.state.summary,
            new_transcript=new_text,
            model="gemini-3-flash-preview",
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

    chunks = [
        TranscriptChunk(
            index=idx,
            text=text,
            timestamp=format_hhmmss(idx * state.chunk_seconds),
            recorded_at=datetime.now(),  # Placeholder - ideally from JSONL
        )
        for idx, text in chunks_data
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
