from pathlib import Path

from livetranscription.app_settings import (
    AppSettings,
    SavedAudioDevice,
    load_app_settings,
    save_app_settings,
)


def test_load_missing_settings_returns_defaults(tmp_path: Path):
    settings = load_app_settings(tmp_path / "missing.json")

    assert settings.default_devices == []
    assert settings.chunk_seconds == 30
    assert settings.summary_minutes == 5
    assert settings.auto_record_enabled is False
    assert settings.auto_record_start_window_minutes == 2
    assert settings.auto_record_join_grace_minutes == 3
    assert settings.auto_record_poll_seconds == 30
    assert settings.auto_record_require_meeting_link is True
    assert settings.auto_record_skip_private_events is True


def test_save_and_load_settings_round_trip(tmp_path: Path):
    path = tmp_path / "app_settings.json"
    save_app_settings(
        path,
        AppSettings(
            default_devices=[
                SavedAudioDevice(index=1, name="AirPods Max"),
                SavedAudioDevice(index=3, name="External Microphone"),
            ],
            chunk_seconds=15,
            summary_minutes=3,
            auto_record_enabled=True,
            auto_record_start_window_minutes=4,
            auto_record_join_grace_minutes=5,
            auto_record_poll_seconds=20,
            auto_record_require_meeting_link=False,
            auto_record_skip_private_events=False,
            google_calendar_credentials_path="/Users/dhope/Downloads/calendar.json",
        ),
    )

    settings = load_app_settings(path)

    assert settings.default_devices == [
        SavedAudioDevice(index=1, name="AirPods Max"),
        SavedAudioDevice(index=3, name="External Microphone"),
    ]
    assert settings.chunk_seconds == 15
    assert settings.summary_minutes == 3
    assert settings.auto_record_enabled is True
    assert settings.auto_record_start_window_minutes == 4
    assert settings.auto_record_join_grace_minutes == 5
    assert settings.auto_record_poll_seconds == 20
    assert settings.auto_record_require_meeting_link is False
    assert settings.auto_record_skip_private_events is False
    assert settings.google_calendar_credentials_path == "/Users/dhope/Downloads/calendar.json"
    assert settings.updated_at is not None


def test_invalid_settings_values_fall_back_to_bounds(tmp_path: Path):
    path = tmp_path / "app_settings.json"
    path.write_text(
        """
        {
          "default_devices": [{"index": "2", "name": "External Microphone"}, {"bad": true}],
          "chunk_seconds": 2,
          "summary_minutes": 500,
          "auto_record_start_window_minutes": 100,
          "auto_record_join_grace_minutes": -1,
          "auto_record_poll_seconds": 3
        }
        """,
        encoding="utf-8",
    )

    settings = load_app_settings(path)

    assert settings.default_devices == [SavedAudioDevice(index=2, name="External Microphone")]
    assert settings.chunk_seconds == 5
    assert settings.summary_minutes == 60
    assert settings.auto_record_start_window_minutes == 30
    assert settings.auto_record_join_grace_minutes == 0
    assert settings.auto_record_poll_seconds == 10
