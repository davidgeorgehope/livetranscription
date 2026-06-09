from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import re
from typing import Any, Optional

from .app_settings import AppSettings


CALENDAR_SCOPES = ["https://www.googleapis.com/auth/calendar.readonly"]
MEETING_URL_RE = re.compile(
    r"https?://[^\s<>)\"']*"
    r"(?:meet\.google\.com|zoom\.us|teams\.microsoft\.com|webex\.com|chime\.aws)"
    r"[^\s<>)\"']*",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class CalendarMeeting:
    event_id: str
    title: str
    start: datetime
    end: datetime
    attendees: list[str]
    meeting_url: Optional[str] = None
    calendar_id: str = "primary"


def fetch_google_calendar_meetings(
    settings: AppSettings,
    *,
    settings_dir: Path,
    now: Optional[datetime] = None,
    allow_interactive_auth: bool = False,
) -> list[CalendarMeeting]:
    """Fetch candidate meetings that are starting soon enough to auto-record."""
    if now is None:
        now = datetime.now(timezone.utc)
    elif now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)

    if not settings.google_calendar_credentials_path:
        raise RuntimeError("Google Calendar credentials path is not configured.")

    credentials_path = Path(settings.google_calendar_credentials_path).expanduser()
    if not credentials_path.exists():
        raise RuntimeError(f"Google Calendar credentials file not found: {credentials_path}")

    service = _build_calendar_service(
        credentials_path,
        settings_dir / "google_calendar_token.json",
        allow_interactive_auth=allow_interactive_auth,
    )
    time_min = now - timedelta(minutes=settings.auto_record_join_grace_minutes)
    time_max = now + timedelta(minutes=settings.auto_record_start_window_minutes)

    response = service.events().list(
        calendarId="primary",
        timeMin=_to_google_time(time_min),
        timeMax=_to_google_time(time_max),
        singleEvents=True,
        orderBy="startTime",
        maxResults=10,
    ).execute()

    meetings: list[CalendarMeeting] = []
    for event in response.get("items", []):
        meeting = _event_to_meeting(
            event,
            calendar_id="primary",
            settings=settings,
            now=now,
        )
        if meeting is not None:
            meetings.append(meeting)

    return meetings


def _build_calendar_service(
    credentials_path: Path,
    token_path: Path,
    *,
    allow_interactive_auth: bool,
):
    try:
        from google.auth.transport.requests import Request
        from google.oauth2.credentials import Credentials
        from google.oauth2 import service_account
        from google_auth_oauthlib.flow import InstalledAppFlow
        from googleapiclient.discovery import build
    except ImportError as exc:
        raise RuntimeError(
            "Google Calendar support requires google-api-python-client and "
            "google-auth-oauthlib. Run: .venv/bin/pip install -e ."
        ) from exc

    credentials_data = json.loads(credentials_path.read_text(encoding="utf-8"))
    if credentials_data.get("type") == "service_account":
        credentials = service_account.Credentials.from_service_account_file(
            str(credentials_path),
            scopes=CALENDAR_SCOPES,
        )
    else:
        credentials = None
        if token_path.exists():
            credentials = Credentials.from_authorized_user_file(str(token_path), CALENDAR_SCOPES)

        if credentials and credentials.expired and credentials.refresh_token:
            credentials.refresh(Request())

        if not credentials or not credentials.valid:
            if not allow_interactive_auth:
                raise RuntimeError(
                    "Google Calendar is not authorized yet. Click Check Now in Settings once "
                    "to complete Google OAuth."
                )
            flow = InstalledAppFlow.from_client_secrets_file(
                str(credentials_path),
                CALENDAR_SCOPES,
            )
            credentials = flow.run_local_server(port=0)
            token_path.parent.mkdir(parents=True, exist_ok=True)
            token_path.write_text(credentials.to_json(), encoding="utf-8")

    return build("calendar", "v3", credentials=credentials, cache_discovery=False)


def _event_to_meeting(
    event: dict[str, Any],
    *,
    calendar_id: str,
    settings: AppSettings,
    now: datetime,
) -> Optional[CalendarMeeting]:
    if event.get("status") == "cancelled":
        return None

    if settings.auto_record_skip_private_events and event.get("visibility") == "private":
        return None

    if _self_declined(event):
        return None

    start = _parse_event_time(event.get("start", {}))
    if start is None:
        return None

    end = _parse_event_time(event.get("end", {})) or (start + timedelta(hours=1))
    if end <= now:
        return None

    earliest_start = now - timedelta(minutes=settings.auto_record_join_grace_minutes)
    latest_start = now + timedelta(minutes=settings.auto_record_start_window_minutes)
    if start < earliest_start or start > latest_start:
        return None

    meeting_url = _extract_meeting_url(event)
    if settings.auto_record_require_meeting_link and not meeting_url:
        return None

    attendees = _extract_attendees(event)
    title = event.get("summary") or "Calendar meeting"
    event_id = f"{calendar_id}:{event.get('id', '')}"

    return CalendarMeeting(
        event_id=event_id,
        title=title,
        start=start,
        end=end,
        attendees=attendees,
        meeting_url=meeting_url,
        calendar_id=calendar_id,
    )


def _parse_event_time(data: dict[str, Any]) -> Optional[datetime]:
    value = data.get("dateTime")
    if not value:
        return None
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _to_google_time(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _self_declined(event: dict[str, Any]) -> bool:
    for attendee in event.get("attendees", []):
        if attendee.get("self") and attendee.get("responseStatus") == "declined":
            return True
    return False


def _extract_attendees(event: dict[str, Any]) -> list[str]:
    attendees: list[str] = []
    for attendee in event.get("attendees", []):
        name = attendee.get("displayName") or attendee.get("email")
        if name and not attendee.get("self"):
            attendees.append(name)
    return attendees


def _extract_meeting_url(event: dict[str, Any]) -> Optional[str]:
    candidates: list[str] = []
    hangout_link = event.get("hangoutLink")
    if isinstance(hangout_link, str):
        candidates.append(hangout_link)

    for entry in event.get("conferenceData", {}).get("entryPoints", []):
        uri = entry.get("uri")
        if isinstance(uri, str):
            candidates.append(uri)

    for key in ("location", "description"):
        value = event.get(key)
        if isinstance(value, str):
            candidates.append(value)

    for candidate in candidates:
        match = MEETING_URL_RE.search(candidate)
        if match:
            return match.group(0).rstrip(".,")

    return None
