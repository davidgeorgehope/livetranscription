from __future__ import annotations

from datetime import datetime
from pathlib import Path
import signal
import subprocess
import time
from typing import Optional

import typer
from rich.console import Console
from rich.markdown import Markdown
from rich.table import Table

from livetranscription.chunk_watcher import (
    find_next_chunk,
    find_next_completed_chunk,
    max_chunk_index,
    wait_for_file_stable,
)
from livetranscription.ffmpeg_capture import (
    ffmpeg_list_avfoundation_devices,
    filter_devices,
    start_ffmpeg_segmenter,
)
from livetranscription.session_store import (
    SessionState,
    append_jsonl,
    append_transcript_text,
    init_session_dir,
    load_state,
    load_transcript_since,
    resolve_session_paths,
    save_state,
    write_summary,
)
from livetranscription.summarize import update_running_summary
from livetranscription.transcribe import transcribe_file_whisper

app = typer.Typer(add_completion=False, help="Local live transcription (macOS).")
console = Console()


@app.command()
def devices() -> None:
    """List macOS AVFoundation devices (audio + video)."""
    try:
        devices = ffmpeg_list_avfoundation_devices()
    except Exception as exc:
        console.print(f"[red]Error:[/red] {exc}")
        raise typer.Exit(code=1)

    audio = filter_devices(devices, kind="audio")
    video = filter_devices(devices, kind="video")

    table = Table(title="AVFoundation devices (ffmpeg)")
    table.add_column("Kind", style="bold")
    table.add_column("Index", justify="right")
    table.add_column("Name")
    for d in video + audio:
        table.add_row(d.kind, str(d.index), d.name)
    console.print(table)

    if audio:
        console.print("\nAudio capture examples:")
        console.print(f"  livetranscribe run --device {audio[0].index}")
        if len(audio) >= 2:
            console.print(f"  livetranscribe run --device {audio[0].index},{audio[1].index}  # mix two devices")


@app.command()
def run(
    device: str = typer.Option(..., help="Audio device index, e.g. '0' or '0,1' to mix."),
    chunk_seconds: int = typer.Option(30, min=5, max=300),
    summary_minutes: int = typer.Option(5, min=1, max=60),
    out_dir: Optional[Path] = typer.Option(None, help="Session output folder."),
    keep_audio: bool = typer.Option(False, help="Keep audio chunk files."),
    language: Optional[str] = typer.Option(None, help="Optional language hint (e.g., 'en')."),
    model: str = typer.Option("whisper-1", help="Transcription model."),
    summary_model: str = typer.Option("gpt-4o-mini", help="Model for summaries."),
) -> None:
    """Record, transcribe chunks, and write rolling summaries."""
    session_dir = out_dir
    if session_dir is None:
        stamp = datetime.now().strftime("%Y-%m-%d_%H%M%S")
        session_dir = Path("sessions") / stamp

    paths = resolve_session_paths(session_dir)
    init_session_dir(paths)

    state = load_state(paths)
    if state is None:
        state = SessionState.new(chunk_seconds=chunk_seconds)
    else:
        if state.chunk_seconds != chunk_seconds:
            console.print(
                f"[yellow]Warning:[/yellow] session chunk_seconds={state.chunk_seconds} "
                f"does not match --chunk-seconds={chunk_seconds}; using session value."
            )
        chunk_seconds = state.chunk_seconds

    pending_for_summary = [text for _, text in load_transcript_since(paths, after_index=state.last_summarized_index)]

    max_existing_chunk = max_chunk_index(paths.chunks_dir)
    segment_start_number = max(max_existing_chunk, state.last_processed_index) + 1

    console.print(f"Session: [bold]{session_dir}[/bold]")
    console.print("Starting ffmpeg capture… (Ctrl+C to stop)")

    ffmpeg_proc = start_ffmpeg_segmenter(
        device=device,
        chunk_seconds=chunk_seconds,
        output_pattern=paths.chunks_dir / "out%05d.wav",
        stderr_path=paths.ffmpeg_log,
        segment_start_number=segment_start_number,
    )

    last_processed_index = state.last_processed_index
    save_state(paths, state)
    summary_interval_seconds = summary_minutes * 60
    next_summary_at = time.monotonic() + summary_interval_seconds

    def maybe_update_summary(*, force: bool) -> None:
        nonlocal next_summary_at, pending_for_summary, state

        now = time.monotonic()
        if not force and now < next_summary_at:
            return

        while now >= next_summary_at:
            next_summary_at += summary_interval_seconds

        if not pending_for_summary:
            return

        console.print("Updating summary…")
        new_block = "\n".join(pending_for_summary).strip()
        try:
            updated = update_running_summary(
                previous_summary=state.summary,
                new_transcript=new_block,
                model=summary_model,
            )
        except Exception as exc:
            console.print(f"[red]Summary update failed:[/red] {exc}")
            return

        state.summary = updated
        state.last_summarized_index = state.last_processed_index
        write_summary(paths, summary=updated)
        save_state(paths, state)
        pending_for_summary = []
        console.print("Summary updated:")
        console.print(Markdown(updated))

    def process_chunk(chunk_index: int, chunk_path: Path) -> None:
        nonlocal last_processed_index, pending_for_summary, state

        wait_for_file_stable(chunk_path)
        offset = chunk_index * chunk_seconds
        console.print(f"Transcribing chunk {chunk_index} ({offset}s)…")

        try:
            text = transcribe_file_whisper(chunk_path, model=model, language=language)
            if not text.strip():
                text = "(silence)"

            append_transcript_text(paths, chunk_index=chunk_index, chunk_seconds=chunk_seconds, text=text)
            append_jsonl(
                paths,
                {
                    "index": chunk_index,
                    "chunk_file": str(chunk_path.relative_to(paths.session_dir)),
                    "text": text,
                    "model": model,
                    "language": language,
                    "recorded_at": datetime.now().isoformat(timespec="seconds"),
                },
            )
            console.print(text)

            pending_for_summary.append(text)
            state.last_processed_index = chunk_index
            last_processed_index = chunk_index
            save_state(paths, state)

            if not keep_audio:
                chunk_path.unlink(missing_ok=True)

        except Exception as exc:
            console.print(f"[red]Transcription failed[/red] for chunk {chunk_index}: {exc}")
            failed_path = paths.failed_dir / chunk_path.name
            try:
                chunk_path.rename(failed_path)
            except Exception:
                failed_path = chunk_path

            append_jsonl(
                paths,
                {
                    "index": chunk_index,
                    "chunk_file": str(failed_path.relative_to(paths.session_dir)),
                    "error": str(exc),
                    "model": model,
                    "language": language,
                    "recorded_at": datetime.now().isoformat(timespec="seconds"),
                },
            )

            state.last_processed_index = chunk_index
            last_processed_index = chunk_index
            save_state(paths, state)

    try:
        while True:
            chunk = find_next_completed_chunk(paths.chunks_dir, after_index=last_processed_index)
            if chunk is None:
                if ffmpeg_proc.poll() is not None:
                    console.print("[red]ffmpeg exited unexpectedly.[/red] See ffmpeg.log for details.")
                    raise typer.Exit(code=1)
                maybe_update_summary(force=False)
                time.sleep(0.2)
                continue

            process_chunk(chunk.index, chunk.path)
            maybe_update_summary(force=False)

    except KeyboardInterrupt:
        console.print("\nStopping…")
    finally:
        if ffmpeg_proc.poll() is None:
            ffmpeg_proc.send_signal(signal.SIGINT)
            try:
                ffmpeg_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                ffmpeg_proc.terminate()
                ffmpeg_proc.wait(timeout=5)

        # Drain any final segment(s) written during shutdown.
        while True:
            chunk = find_next_chunk(paths.chunks_dir, after_index=last_processed_index)
            if chunk is None:
                break
            process_chunk(chunk.index, chunk.path)

        maybe_update_summary(force=True)


def main() -> None:
    app()


if __name__ == "__main__":
    main()
