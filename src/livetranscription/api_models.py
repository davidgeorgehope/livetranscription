"""
Pydantic models for the REST API.
"""

from __future__ import annotations

from datetime import datetime
from enum import Enum
from typing import Optional

from pydantic import BaseModel, Field


class MeetingType(str, Enum):
    """Type of meeting, affects coaching strategy."""

    SALES_CALL = "sales_call"
    PRODUCT_DEMO = "product_demo"
    DISCOVERY_CALL = "discovery_call"
    NEGOTIATION = "negotiation"
    CUSTOMER_SUCCESS = "customer_success"
    INTERNAL_MEETING = "internal_meeting"
    ONE_ON_ONE = "one_on_one"


class AlertType(str, Enum):
    """Type of coaching alert."""

    OBJECTION = "objection"
    SUGGESTED_QUESTION = "suggested_question"
    MISSING_TOPIC = "missing_topic"
    COMPETITOR_MENTION = "competitor_mention"
    PACE_WARNING = "pace_warning"
    CUSTOM_REMINDER = "custom_reminder"


class SessionStatus(str, Enum):
    """Status of a transcription session."""

    CREATED = "created"
    PREPARED = "prepared"  # Meeting prep submitted
    RECORDING = "recording"
    PAUSED = "paused"
    STOPPED = "stopped"


# ----- Request Models -----


class AttendeeCreate(BaseModel):
    """Attendee information for meeting prep."""

    name: str
    role: Optional[str] = None
    company: Optional[str] = None
    notes: Optional[str] = None


class TalkingPointCreate(BaseModel):
    """A talking point to cover during the meeting."""

    topic: str
    priority: int = Field(default=1, ge=1, le=3)  # 1=high, 2=medium, 3=low
    notes: Optional[str] = None


class MeetingPrepCreate(BaseModel):
    """Request model for submitting meeting prep."""

    meeting_type: MeetingType = MeetingType.SALES_CALL
    attendees: list[AttendeeCreate] = Field(default_factory=list)
    objectives: list[str] = Field(default_factory=list)
    talking_points: list[TalkingPointCreate] = Field(default_factory=list)
    competitors: list[str] = Field(default_factory=list)
    custom_reminders: list[str] = Field(default_factory=list)
    pricing_notes: Optional[str] = None
    discount_authority: Optional[str] = None
    additional_context: Optional[str] = None


class SessionCreate(BaseModel):
    """Request model for creating a new session."""

    device_index: str  # Can be single index "0" or comma-separated "0,1" for mixing
    chunk_seconds: int = 30
    summary_minutes: int = 5
    language: Optional[str] = None
    keep_audio: bool = False


class SessionStartRequest(BaseModel):
    """Request model for starting a session."""

    device_index: Optional[str] = None  # Override if different from creation


# ----- Response Models -----


class AttendeeResponse(BaseModel):
    """Attendee information in responses."""

    name: str
    role: Optional[str] = None
    company: Optional[str] = None
    notes: Optional[str] = None


class TalkingPointResponse(BaseModel):
    """Talking point in responses, with coverage tracking."""

    topic: str
    priority: int
    notes: Optional[str] = None
    mentioned: bool = False
    mentioned_at: Optional[datetime] = None


class MeetingPrepResponse(BaseModel):
    """Response model for meeting prep."""

    meeting_type: MeetingType
    attendees: list[AttendeeResponse]
    objectives: list[str]
    talking_points: list[TalkingPointResponse]
    competitors: list[str]
    custom_reminders: list[str]
    pricing_notes: Optional[str] = None
    discount_authority: Optional[str] = None
    additional_context: Optional[str] = None


class TranscriptSegment(BaseModel):
    """A segment of transcript with speaker attribution."""

    speaker: str
    text: str
    start: float = 0.0
    end: float = 0.0


class TranscriptChunk(BaseModel):
    """A single transcript chunk."""

    index: int
    text: str
    timestamp: str  # HH:MM:SS format
    recorded_at: datetime
    segments: list[TranscriptSegment] = Field(default_factory=list)


class CoachingAlertResponse(BaseModel):
    """A coaching alert/suggestion."""

    id: str
    alert_type: AlertType
    content: str
    suggestion: Optional[str] = None
    timestamp: datetime
    dismissed: bool = False
    metadata: dict = Field(default_factory=dict)


class SessionResponse(BaseModel):
    """Response model for session details."""

    id: str
    status: SessionStatus
    created_at: datetime
    started_at: Optional[datetime] = None
    stopped_at: Optional[datetime] = None
    chunk_seconds: int
    summary_minutes: int
    chunks_processed: int = 0
    meeting_prep: Optional[MeetingPrepResponse] = None


class SessionListResponse(BaseModel):
    """Response model for listing sessions."""

    sessions: list[SessionResponse]


class TranscriptResponse(BaseModel):
    """Response model for transcript data."""

    session_id: str
    chunks: list[TranscriptChunk]
    full_text: str
    last_updated: Optional[datetime] = None


class SummaryResponse(BaseModel):
    """Response model for summary data."""

    session_id: str
    summary: str
    decisions: list[str] = Field(default_factory=list)
    action_items: list[str] = Field(default_factory=list)
    open_questions: list[str] = Field(default_factory=list)
    last_updated: Optional[datetime] = None


class CoachingHistoryResponse(BaseModel):
    """Response model for coaching history."""

    session_id: str
    alerts: list[CoachingAlertResponse]


class DeviceInfo(BaseModel):
    """Audio device information."""

    index: int
    name: str
    type: str  # "audio" or "video"


class DeviceListResponse(BaseModel):
    """Response model for listing audio devices."""

    devices: list[DeviceInfo]


# ----- WebSocket Message Models -----


class WSMessageBase(BaseModel):
    """Base class for WebSocket messages."""

    type: str
    session_id: str
    timestamp: datetime = Field(default_factory=datetime.now)


class WSTranscriptChunk(WSMessageBase):
    """WebSocket message for new transcript chunk."""

    type: str = "transcript_chunk"
    data: TranscriptChunk


class WSCoachingAlert(WSMessageBase):
    """WebSocket message for coaching alert."""

    type: str = "coaching_alert"
    data: CoachingAlertResponse


class WSSummaryUpdate(WSMessageBase):
    """WebSocket message for summary update."""

    type: str = "summary_update"
    data: SummaryResponse


class WSPaceWarning(WSMessageBase):
    """WebSocket message for pace warning."""

    type: str = "pace_warning"
    data: dict  # {"minutes_talking": int, "message": str}


class WSSessionStatus(WSMessageBase):
    """WebSocket message for session status change."""

    type: str = "session_status"
    data: dict  # {"status": SessionStatus, "message": str}
