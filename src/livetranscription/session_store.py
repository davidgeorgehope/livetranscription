from __future__ import annotations

from dataclasses import asdict, dataclass, field
from datetime import datetime
from enum import Enum
import json
from pathlib import Path
from typing import Any, Optional
import uuid


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


@dataclass
class Attendee:
    """Information about a meeting attendee."""

    name: str
    role: Optional[str] = None
    company: Optional[str] = None
    notes: Optional[str] = None


@dataclass
class TalkingPoint:
    """A talking point to cover during the meeting."""

    topic: str
    priority: int = 1  # 1=high, 2=medium, 3=low
    notes: Optional[str] = None
    mentioned: bool = False
    mentioned_at: Optional[str] = None


@dataclass
class MeetingPrepContext:
    """Pre-meeting context for coaching."""

    meeting_type: MeetingType = MeetingType.SALES_CALL
    attendees: list[Attendee] = field(default_factory=list)
    objectives: list[str] = field(default_factory=list)
    talking_points: list[TalkingPoint] = field(default_factory=list)
    competitors: list[str] = field(default_factory=list)
    custom_reminders: list[str] = field(default_factory=list)
    pricing_notes: Optional[str] = None
    discount_authority: Optional[str] = None
    additional_context: Optional[str] = None

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for JSON serialization."""
        return {
            "meeting_type": self.meeting_type.value,
            "attendees": [asdict(a) for a in self.attendees],
            "objectives": self.objectives,
            "talking_points": [asdict(tp) for tp in self.talking_points],
            "competitors": self.competitors,
            "custom_reminders": self.custom_reminders,
            "pricing_notes": self.pricing_notes,
            "discount_authority": self.discount_authority,
            "additional_context": self.additional_context,
        }

    @staticmethod
    def from_dict(data: dict[str, Any]) -> "MeetingPrepContext":
        """Create from dictionary."""
        return MeetingPrepContext(
            meeting_type=MeetingType(data.get("meeting_type", "sales_call")),
            attendees=[Attendee(**a) for a in data.get("attendees", [])],
            objectives=data.get("objectives", []),
            talking_points=[TalkingPoint(**tp) for tp in data.get("talking_points", [])],
            competitors=data.get("competitors", []),
            custom_reminders=data.get("custom_reminders", []),
            pricing_notes=data.get("pricing_notes"),
            discount_authority=data.get("discount_authority"),
            additional_context=data.get("additional_context"),
        )


@dataclass
class CoachingAlert:
    """A coaching alert generated during the meeting."""

    id: str
    alert_type: AlertType
    content: str
    suggestion: Optional[str] = None
    timestamp: str = ""
    dismissed: bool = False
    metadata: dict[str, Any] = field(default_factory=dict)

    def __post_init__(self) -> None:
        if not self.id:
            self.id = str(uuid.uuid4())[:8]
        if not self.timestamp:
            self.timestamp = datetime.now().isoformat(timespec="seconds")

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for JSON serialization."""
        return {
            "id": self.id,
            "alert_type": self.alert_type.value,
            "content": self.content,
            "suggestion": self.suggestion,
            "timestamp": self.timestamp,
            "dismissed": self.dismissed,
            "metadata": self.metadata,
        }

    @staticmethod
    def from_dict(data: dict[str, Any]) -> "CoachingAlert":
        """Create from dictionary."""
        return CoachingAlert(
            id=data.get("id", ""),
            alert_type=AlertType(data.get("alert_type", "suggested_question")),
            content=data.get("content", ""),
            suggestion=data.get("suggestion"),
            timestamp=data.get("timestamp", ""),
            dismissed=data.get("dismissed", False),
            metadata=data.get("metadata", {}),
        )


@dataclass
class TranscriptSegment:
    """A segment of transcript with speaker attribution."""

    speaker: str
    text: str
    start_time: float = 0.0
    end_time: float = 0.0

    def to_dict(self) -> dict[str, Any]:
        return {
            "speaker": self.speaker,
            "text": self.text,
            "start": self.start_time,
            "end": self.end_time,
        }

    @staticmethod
    def from_dict(data: dict[str, Any]) -> "TranscriptSegment":
        return TranscriptSegment(
            speaker=data.get("speaker", "Unknown"),
            text=data.get("text", ""),
            start_time=data.get("start", 0.0),
            end_time=data.get("end", 0.0),
        )


@dataclass
class TranscriptResult:
    """Result from transcription with optional diarization."""

    text: str  # Full text for backward compatibility
    segments: list[TranscriptSegment] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "text": self.text,
            "segments": [s.to_dict() for s in self.segments],
        }

    @staticmethod
    def from_dict(data: dict[str, Any]) -> "TranscriptResult":
        return TranscriptResult(
            text=data.get("text", ""),
            segments=[TranscriptSegment.from_dict(s) for s in data.get("segments", [])],
        )

    def format_with_speakers(self) -> str:
        """Format transcript with speaker labels."""
        if not self.segments:
            return self.text
        return "\n".join(f"[{s.speaker}] {s.text}" for s in self.segments)


@dataclass
class SessionState:
    created_at: str
    chunk_seconds: int
    last_processed_index: int = -1
    last_summarized_index: int = -1
    summary: str = ""

    @staticmethod
    def new(*, chunk_seconds: int) -> "SessionState":
        return SessionState(created_at=datetime.now().isoformat(timespec="seconds"), chunk_seconds=chunk_seconds)

    @staticmethod
    def from_json(data: dict[str, Any]) -> "SessionState":
        return SessionState(
            created_at=str(data.get("created_at", "")),
            chunk_seconds=int(data.get("chunk_seconds", 30)),
            last_processed_index=int(data.get("last_processed_index", -1)),
            last_summarized_index=int(data.get("last_summarized_index", -1)),
            summary=str(data.get("summary", "")),
        )


@dataclass(frozen=True)
class SessionPaths:
    session_dir: Path
    chunks_dir: Path
    failed_dir: Path
    transcript_txt: Path
    transcript_jsonl: Path
    summary_md: Path
    state_json: Path
    ffmpeg_log: Path
    meeting_prep_json: Path
    coaching_jsonl: Path


def resolve_session_paths(session_dir: Path) -> SessionPaths:
    return SessionPaths(
        session_dir=session_dir,
        chunks_dir=session_dir / "chunks",
        failed_dir=session_dir / "failed_chunks",
        transcript_txt=session_dir / "transcript.txt",
        transcript_jsonl=session_dir / "transcript.jsonl",
        summary_md=session_dir / "summary.md",
        state_json=session_dir / "state.json",
        ffmpeg_log=session_dir / "ffmpeg.log",
        meeting_prep_json=session_dir / "meeting_prep.json",
        coaching_jsonl=session_dir / "coaching.jsonl",
    )


def init_session_dir(paths: SessionPaths) -> None:
    paths.session_dir.mkdir(parents=True, exist_ok=True)
    paths.chunks_dir.mkdir(parents=True, exist_ok=True)
    paths.failed_dir.mkdir(parents=True, exist_ok=True)


def load_state(paths: SessionPaths) -> Optional[SessionState]:
    if not paths.state_json.exists():
        return None
    data = json.loads(paths.state_json.read_text(encoding="utf-8"))
    return SessionState.from_json(data)


def save_state(paths: SessionPaths, state: SessionState) -> None:
    paths.state_json.write_text(json.dumps(asdict(state), indent=2, sort_keys=True) + "\n", encoding="utf-8")


def append_jsonl(paths: SessionPaths, obj: dict[str, Any]) -> None:
    with paths.transcript_jsonl.open("a", encoding="utf-8") as f:
        f.write(json.dumps(obj, ensure_ascii=False) + "\n")


def format_hhmmss(total_seconds: int) -> str:
    hours = total_seconds // 3600
    minutes = (total_seconds % 3600) // 60
    seconds = total_seconds % 60
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}"


def append_transcript_text(paths: SessionPaths, *, chunk_index: int, chunk_seconds: int, text: str) -> None:
    offset = format_hhmmss(chunk_index * chunk_seconds)
    line = f"[{offset}] {text.strip()}\n"
    with paths.transcript_txt.open("a", encoding="utf-8") as f:
        f.write(line)


def write_summary(paths: SessionPaths, *, summary: str, updated_at: Optional[str] = None) -> None:
    if updated_at is None:
        updated_at = datetime.now().isoformat(timespec="seconds")
    content = f"# Running summary\n\nLast updated: {updated_at}\n\n{summary.strip()}\n"
    paths.summary_md.write_text(content, encoding="utf-8")


@dataclass
class TranscriptChunkData:
    """Data for a transcript chunk including segments."""

    index: int
    text: str
    segments: list[TranscriptSegment]
    recorded_at: Optional[str] = None


def load_transcript_since(paths: SessionPaths, *, after_index: int) -> list[TranscriptChunkData]:
    if not paths.transcript_jsonl.exists():
        return []
    out: list[TranscriptChunkData] = []
    for line in paths.transcript_jsonl.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        idx = obj.get("index")
        text = obj.get("text")
        if not isinstance(idx, int) or not isinstance(text, str):
            continue
        if idx > after_index and text.strip():
            segments = [TranscriptSegment.from_dict(s) for s in obj.get("segments", [])]
            out.append(TranscriptChunkData(
                index=idx,
                text=text,
                segments=segments,
                recorded_at=obj.get("recorded_at"),
            ))
    out.sort(key=lambda t: t.index)
    return out


def load_full_transcript(paths: SessionPaths) -> str:
    """Load the full transcript text."""
    if not paths.transcript_txt.exists():
        return ""
    return paths.transcript_txt.read_text(encoding="utf-8")


# ----- Meeting Prep Persistence -----


def save_meeting_prep(paths: SessionPaths, prep: MeetingPrepContext) -> None:
    """Save meeting prep context to JSON file."""
    paths.meeting_prep_json.write_text(
        json.dumps(prep.to_dict(), indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


def load_meeting_prep(paths: SessionPaths) -> Optional[MeetingPrepContext]:
    """Load meeting prep context from JSON file."""
    if not paths.meeting_prep_json.exists():
        return None
    try:
        data = json.loads(paths.meeting_prep_json.read_text(encoding="utf-8"))
        return MeetingPrepContext.from_dict(data)
    except (json.JSONDecodeError, KeyError, ValueError):
        return None


def update_talking_point_mentioned(
    paths: SessionPaths, topic: str, mentioned_at: Optional[str] = None
) -> None:
    """Mark a talking point as mentioned in the meeting prep."""
    prep = load_meeting_prep(paths)
    if prep is None:
        return

    if mentioned_at is None:
        mentioned_at = datetime.now().isoformat(timespec="seconds")

    for tp in prep.talking_points:
        if tp.topic.lower() == topic.lower() and not tp.mentioned:
            tp.mentioned = True
            tp.mentioned_at = mentioned_at
            break

    save_meeting_prep(paths, prep)


# ----- Coaching Alert Persistence -----


def append_coaching_alert(paths: SessionPaths, alert: CoachingAlert) -> None:
    """Append a coaching alert to the JSONL file."""
    with paths.coaching_jsonl.open("a", encoding="utf-8") as f:
        f.write(json.dumps(alert.to_dict(), ensure_ascii=False) + "\n")


def load_coaching_alerts(paths: SessionPaths) -> list[CoachingAlert]:
    """Load all coaching alerts from the JSONL file."""
    if not paths.coaching_jsonl.exists():
        return []

    alerts: list[CoachingAlert] = []
    for line in paths.coaching_jsonl.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            data = json.loads(line)
            alerts.append(CoachingAlert.from_dict(data))
        except (json.JSONDecodeError, KeyError, ValueError):
            continue

    return alerts


def dismiss_coaching_alert(paths: SessionPaths, alert_id: str) -> bool:
    """
    Mark a coaching alert as dismissed.

    Returns True if the alert was found and updated.
    """
    alerts = load_coaching_alerts(paths)
    found = False

    for alert in alerts:
        if alert.id == alert_id:
            alert.dismissed = True
            found = True
            break

    if found:
        # Rewrite the entire file with updated alerts
        with paths.coaching_jsonl.open("w", encoding="utf-8") as f:
            for alert in alerts:
                f.write(json.dumps(alert.to_dict(), ensure_ascii=False) + "\n")

    return found

