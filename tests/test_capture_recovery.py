import os
import signal
import subprocess
import time
from datetime import datetime, timedelta

from livetranscription.server import (
    _capture_is_stalled,
    _capture_stall_timeout_seconds,
    _next_segment_number,
    _shutdown_ffmpeg,
)


class FakeProcess:
    """Stands in for an ffmpeg Popen that may ignore some signals."""

    def __init__(self, dies_on=("SIGINT", "SIGTERM", "SIGKILL")):
        self.dies_on = dies_on
        self.signals = []
        self.returncode = None

    def poll(self):
        return self.returncode

    def send_signal(self, sig):
        assert sig == signal.SIGINT
        self._receive("SIGINT")

    def terminate(self):
        self._receive("SIGTERM")

    def kill(self):
        self._receive("SIGKILL")

    def _receive(self, name):
        self.signals.append(name)
        if name in self.dies_on:
            self.returncode = 0

    def wait(self, timeout=None):
        if self.returncode is None:
            raise subprocess.TimeoutExpired(cmd="ffmpeg", timeout=timeout)
        return self.returncode


def test_shutdown_stops_at_sigint_when_process_cooperates():
    proc = FakeProcess(dies_on=("SIGINT", "SIGTERM", "SIGKILL"))
    _shutdown_ffmpeg(proc, sigint_timeout=0.01)
    assert proc.signals == ["SIGINT"]
    assert proc.poll() == 0


def test_shutdown_escalates_to_sigterm():
    proc = FakeProcess(dies_on=("SIGTERM", "SIGKILL"))
    _shutdown_ffmpeg(proc, sigint_timeout=0.01)
    assert proc.signals == ["SIGINT", "SIGTERM"]
    assert proc.poll() == 0


def test_shutdown_escalates_to_sigkill():
    proc = FakeProcess(dies_on=("SIGKILL",))
    _shutdown_ffmpeg(proc, sigint_timeout=0.01)
    assert proc.signals == ["SIGINT", "SIGTERM", "SIGKILL"]
    assert proc.poll() == 0


def test_shutdown_survives_unkillable_process():
    proc = FakeProcess(dies_on=())
    _shutdown_ffmpeg(proc, sigint_timeout=0.01)
    assert proc.signals == ["SIGINT", "SIGTERM", "SIGKILL"]


def test_shutdown_noop_when_already_exited():
    proc = FakeProcess()
    proc.returncode = 0
    _shutdown_ffmpeg(proc)
    assert proc.signals == []


def test_not_stalled_while_chunks_are_fresh(tmp_path):
    chunk_seconds = 30
    started = datetime.now() - timedelta(hours=1)
    (tmp_path / "out00000.wav").write_bytes(b"x")
    assert not _capture_is_stalled(tmp_path, started, chunk_seconds)


def test_stalled_when_newest_chunk_is_old(tmp_path):
    chunk_seconds = 30
    started = datetime.now() - timedelta(hours=1)
    chunk = tmp_path / "out00000.wav"
    chunk.write_bytes(b"x")
    old = time.time() - _capture_stall_timeout_seconds(chunk_seconds) - 1
    os.utime(chunk, (old, old))
    assert _capture_is_stalled(tmp_path, started, chunk_seconds)


def test_stalled_when_no_chunks_ever_written(tmp_path):
    chunk_seconds = 30
    started = datetime.now() - timedelta(hours=1)
    assert _capture_is_stalled(tmp_path, started, chunk_seconds)


def test_not_stalled_right_after_capture_start(tmp_path):
    chunk_seconds = 30
    assert not _capture_is_stalled(tmp_path, datetime.now(), chunk_seconds)


def test_next_segment_number_continues_after_existing_chunks(tmp_path):
    (tmp_path / "out00003.wav").write_bytes(b"x")
    (tmp_path / "out00007.wav").write_bytes(b"x")
    assert _next_segment_number(tmp_path, last_processed_index=2) == 8


def test_next_segment_number_uses_processed_index_when_chunks_deleted(tmp_path):
    # Processed chunks are deleted when keep_audio is off; numbering must
    # still advance past what was already transcribed.
    assert _next_segment_number(tmp_path, last_processed_index=5) == 6


def test_next_segment_number_for_fresh_session(tmp_path):
    assert _next_segment_number(tmp_path, last_processed_index=-1) == 0
