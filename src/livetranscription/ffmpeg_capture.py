from __future__ import annotations

from dataclasses import dataclass
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Iterable, List, Optional, Sequence


@dataclass(frozen=True)
class AVFoundationDevice:
    index: int
    name: str
    kind: str  # "audio" | "video"


_DEVICE_LINE_RE = re.compile(r"^\[AVFoundation indev @ .+\] \[(\d+)\] (.+)$")


def _require_macos() -> None:
    if sys.platform != "darwin":
        raise RuntimeError("AVFoundation device listing is only supported on macOS.")


def _require_ffmpeg() -> None:
    if shutil.which("ffmpeg") is None:
        raise RuntimeError("ffmpeg not found on PATH. Install with: brew install ffmpeg")


def parse_avfoundation_device_list(output: str) -> list[AVFoundationDevice]:
    devices: list[AVFoundationDevice] = []
    kind: Optional[str] = None
    for raw_line in output.splitlines():
        line = raw_line.strip()
        if "AVFoundation video devices" in line:
            kind = "video"
            continue
        if "AVFoundation audio devices" in line:
            kind = "audio"
            continue

        match = _DEVICE_LINE_RE.match(line)
        if not match or kind not in {"audio", "video"}:
            continue
        devices.append(
            AVFoundationDevice(
                index=int(match.group(1)),
                name=match.group(2),
                kind=kind,
            )
        )
    return devices


def ffmpeg_list_avfoundation_devices(
    ffmpeg_bin: str = "ffmpeg",
    extra_args: Optional[Sequence[str]] = None,
) -> list[AVFoundationDevice]:
    _require_macos()
    _require_ffmpeg()

    cmd: list[str] = [ffmpeg_bin, "-f", "avfoundation", "-list_devices", "true"]
    if extra_args:
        cmd.extend(extra_args)
    cmd.extend(["-i", ""])

    # ffmpeg prints the device list to stderr and exits non-zero due to the dummy input.
    proc = subprocess.run(cmd, capture_output=True, text=True)
    combined = "\n".join([proc.stderr or "", proc.stdout or ""]).strip()
    devices = parse_avfoundation_device_list(combined)
    if not devices:
        raise RuntimeError(
            "Failed to parse AVFoundation devices from ffmpeg output. "
            "Try running manually: ffmpeg -f avfoundation -list_devices true -i \"\""
        )
    return devices


def filter_devices(devices: Iterable[AVFoundationDevice], *, kind: str) -> list[AVFoundationDevice]:
    return [d for d in devices if d.kind == kind]


def _parse_audio_device_indices(device: str) -> list[int]:
    indices: list[int] = []
    for part in device.split(","):
        part = part.strip()
        if not part:
            continue
        try:
            indices.append(int(part))
        except ValueError as exc:
            raise ValueError(f"Invalid --device value: {device!r}") from exc
    if not indices:
        raise ValueError("No audio device indices provided.")
    return indices


def build_ffmpeg_segment_command(
    *,
    device: str,
    chunk_seconds: int,
    output_pattern: Path,
    sample_rate_hz: int = 16000,
    channels: int = 1,
    ffmpeg_bin: str = "ffmpeg",
    loglevel: str = "error",
    segment_start_number: Optional[int] = None,
) -> list[str]:
    _require_macos()
    _require_ffmpeg()

    if chunk_seconds <= 0:
        raise ValueError("chunk_seconds must be > 0")

    indices = _parse_audio_device_indices(device)
    output_pattern.parent.mkdir(parents=True, exist_ok=True)

    cmd: list[str] = [ffmpeg_bin, "-hide_banner", "-loglevel", loglevel]

    if len(indices) == 1:
        cmd += [
            "-f",
            "avfoundation",
            "-thread_queue_size",
            "4096",
            "-i",
            f":{indices[0]}",
        ]
    else:
        for idx in indices:
            cmd += [
                "-f",
                "avfoundation",
                "-thread_queue_size",
                "4096",
                "-i",
                f":{idx}",
            ]
        inputs = "".join([f"[{i}:a]" for i in range(len(indices))])
        cmd += [
            "-filter_complex",
            f"{inputs}amix=inputs={len(indices)}:duration=longest:dropout_transition=2[a]",
            "-map",
            "[a]",
        ]

    cmd += [
        "-ac",
        str(channels),
        "-ar",
        str(sample_rate_hz),
        "-c:a",
        "pcm_s16le",
        "-f",
        "segment",
        "-segment_start_number",
        str(segment_start_number or 0),
        "-segment_time",
        str(chunk_seconds),
        "-reset_timestamps",
        "1",
        str(output_pattern),
    ]
    return cmd


def start_ffmpeg_segmenter(
    *,
    device: str,
    chunk_seconds: int,
    output_pattern: Path,
    stderr_path: Optional[Path] = None,
    sample_rate_hz: int = 16000,
    channels: int = 1,
    segment_start_number: Optional[int] = None,
) -> subprocess.Popen[bytes]:
    cmd = build_ffmpeg_segment_command(
        device=device,
        chunk_seconds=chunk_seconds,
        output_pattern=output_pattern,
        sample_rate_hz=sample_rate_hz,
        channels=channels,
        segment_start_number=segment_start_number,
    )

    stderr_target = subprocess.DEVNULL
    stderr_file = None
    if stderr_path is not None:
        stderr_path.parent.mkdir(parents=True, exist_ok=True)
        stderr_file = stderr_path.open("ab")
        stderr_target = stderr_file

    try:
        return subprocess.Popen(
            cmd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=stderr_target,
        )
    except Exception:
        if stderr_file is not None:
            stderr_file.close()
        raise
