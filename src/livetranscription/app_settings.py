from __future__ import annotations

from dataclasses import asdict, dataclass, field
from datetime import datetime
import json
from pathlib import Path
from typing import Any, Optional


DEFAULT_CHUNK_SECONDS = 30
DEFAULT_SUMMARY_MINUTES = 5


@dataclass(frozen=True)
class SavedAudioDevice:
    index: int
    name: str

    @staticmethod
    def from_dict(data: dict[str, Any]) -> Optional["SavedAudioDevice"]:
        try:
            return SavedAudioDevice(index=int(data["index"]), name=str(data["name"]))
        except (KeyError, TypeError, ValueError):
            return None


@dataclass
class AppSettings:
    default_devices: list[SavedAudioDevice] = field(default_factory=list)
    chunk_seconds: int = DEFAULT_CHUNK_SECONDS
    summary_minutes: int = DEFAULT_SUMMARY_MINUTES
    auto_record_enabled: bool = False
    auto_record_start_window_minutes: int = 2
    auto_record_join_grace_minutes: int = 3
    auto_record_poll_seconds: int = 30
    auto_record_require_meeting_link: bool = True
    auto_record_skip_private_events: bool = True
    google_calendar_credentials_path: Optional[str] = None
    updated_at: Optional[str] = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "default_devices": [asdict(device) for device in self.default_devices],
            "chunk_seconds": self.chunk_seconds,
            "summary_minutes": self.summary_minutes,
            "auto_record_enabled": self.auto_record_enabled,
            "auto_record_start_window_minutes": self.auto_record_start_window_minutes,
            "auto_record_join_grace_minutes": self.auto_record_join_grace_minutes,
            "auto_record_poll_seconds": self.auto_record_poll_seconds,
            "auto_record_require_meeting_link": self.auto_record_require_meeting_link,
            "auto_record_skip_private_events": self.auto_record_skip_private_events,
            "google_calendar_credentials_path": self.google_calendar_credentials_path,
            "updated_at": self.updated_at,
        }

    @staticmethod
    def from_dict(data: dict[str, Any]) -> "AppSettings":
        devices: list[SavedAudioDevice] = []
        for raw_device in data.get("default_devices", []):
            if not isinstance(raw_device, dict):
                continue
            device = SavedAudioDevice.from_dict(raw_device)
            if device is not None:
                devices.append(device)

        return AppSettings(
            default_devices=devices,
            chunk_seconds=_bounded_int(
                data.get("chunk_seconds"),
                default=DEFAULT_CHUNK_SECONDS,
                minimum=5,
                maximum=300,
            ),
            summary_minutes=_bounded_int(
                data.get("summary_minutes"),
                default=DEFAULT_SUMMARY_MINUTES,
                minimum=1,
                maximum=60,
            ),
            auto_record_enabled=bool(data.get("auto_record_enabled", False)),
            auto_record_start_window_minutes=_bounded_int(
                data.get("auto_record_start_window_minutes"),
                default=2,
                minimum=1,
                maximum=30,
            ),
            auto_record_join_grace_minutes=_bounded_int(
                data.get("auto_record_join_grace_minutes"),
                default=3,
                minimum=0,
                maximum=30,
            ),
            auto_record_poll_seconds=_bounded_int(
                data.get("auto_record_poll_seconds"),
                default=30,
                minimum=10,
                maximum=300,
            ),
            auto_record_require_meeting_link=bool(
                data.get("auto_record_require_meeting_link", True)
            ),
            auto_record_skip_private_events=bool(
                data.get("auto_record_skip_private_events", True)
            ),
            google_calendar_credentials_path=_optional_string(
                data.get("google_calendar_credentials_path")
            ),
            updated_at=data.get("updated_at") if isinstance(data.get("updated_at"), str) else None,
        )


def _bounded_int(value: Any, *, default: int, minimum: int, maximum: int) -> int:
    try:
        int_value = int(value)
    except (TypeError, ValueError):
        return default
    return max(minimum, min(maximum, int_value))


def _optional_string(value: Any) -> Optional[str]:
    if not isinstance(value, str):
        return None
    stripped = value.strip()
    return stripped or None


def load_app_settings(path: Path) -> AppSettings:
    if not path.exists():
        return AppSettings()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return AppSettings()
    if not isinstance(data, dict):
        return AppSettings()
    return AppSettings.from_dict(data)


def save_app_settings(path: Path, settings: AppSettings) -> AppSettings:
    path.parent.mkdir(parents=True, exist_ok=True)
    if settings.updated_at is None:
        settings.updated_at = datetime.now().isoformat(timespec="seconds")
    path.write_text(
        json.dumps(settings.to_dict(), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return settings
