# Live Transcription (macOS, local terminal) — MVP Spec

## Goal
Build a local terminal app that:
- captures **microphone + system audio** on macOS (via BlackHole routing)
- transcribes continuously using the **OpenAI Whisper API** (chunked, near‑real‑time)
- every **5 minutes** emits an updated **running summary** (“what’s been covered so far”)

Non-goals (MVP): speaker diarization, true streaming ASR, perfect word-boundary stitching, multi-user hosting.

## High-level approach
Whisper API is file/chunk based, so we’ll:
1. Record audio to disk as small files (e.g., 30s chunks) using `ffmpeg` + `avfoundation`.
2. For each new chunk: send to Whisper → append text to a rolling transcript.
3. Every 5 minutes: summarize incrementally using a chat model:
   - input: `previous_summary` + `new_transcript_since_last_summary`
   - output: updated summary + (optional) action items / decisions / open questions

## Local environment prerequisites
- macOS
- Python 3.11+ (3.12 ok)
- `ffmpeg` installed (`brew install ffmpeg`)
- BlackHole installed (you already did this)
- OpenAI API key in env: `OPENAI_API_KEY=...`

## macOS audio routing (system audio + mic)
You’ll typically create **two** devices in **Audio MIDI Setup**:

### 1) Multi-Output Device (so you can hear + feed BlackHole)
1. Open **Audio MIDI Setup**
2. `+` → **Create Multi-Output Device**
3. Check:
   - **Built-in Output** (or your headphones)
   - **BlackHole 2ch**
4. Set macOS **System Settings → Sound → Output** (or Zoom “Speaker”) to the Multi-Output device.

Result: all system audio plays to your speakers/headphones *and* gets copied into BlackHole.

### 2) Aggregate Device (so our recorder gets mic + system audio)
1. Audio MIDI Setup → `+` → **Create Aggregate Device**
2. Check:
   - **Built-in Microphone** (or your mic)
   - **BlackHole 2ch**
3. Set sample rate consistently (often **48,000 Hz**) for both.

Result: `ffmpeg` can record a single “device” containing both sources.

Notes:
- Prefer **headphones** to prevent speaker→mic feedback/echo.
- Aggregates can be multi-channel; we can downmix to mono for Whisper.

## Audio capture with ffmpeg (reference commands)
List devices and find the **audio device index** for your Aggregate Device:
```bash
ffmpeg -f avfoundation -list_devices true -i ""
```

Record 30s chunks to `./chunks` (replace `<IDX>`):
```bash
mkdir -p chunks
ffmpeg \
  -f avfoundation -i ":<IDX>" \
  -ac 1 -ar 16000 \
  -f segment -segment_time 30 -reset_timestamps 1 \
  chunks/out%05d.wav
```

If you don’t want to create an Aggregate Device, you can also record **two** audio devices and mix them (example indices `0` + `1`):
```bash
ffmpeg \
  -f avfoundation -i ":0" \
  -f avfoundation -i ":1" \
  -filter_complex "[0:a][1:a]amix=inputs=2:duration=longest[a]" -map "[a]" \
  -ac 1 -ar 16000 \
  -f segment -segment_time 30 -reset_timestamps 1 \
  chunks/out%05d.wav
```

MVP strategy:
- chunk length: 15–30s (30s is cheaper/simpler; 15s feels “more live”)
- no overlap initially (optional later: 0.5–1s overlap + de-dupe)

## Output artifacts (local files)
Each run/session writes to a timestamped folder, e.g. `./sessions/2025-12-12_1405/`:
- `transcript.txt` (append-only, human readable)
- `transcript.jsonl` (one JSON per chunk: timestamps, chunk filename, text)
- `summary.md` (running summary updated every 5 minutes)
- `chunks/` (optional; delete after successful transcription unless `--keep-audio`)

## CLI UX (proposal)
Executable name: `livetranscribe`

Commands:
- `livetranscribe devices`  
  Lists `avfoundation` audio devices with indices (parses ffmpeg output).

- `livetranscribe run --device <IDX> [options]`  
  Starts capture + transcription + summarization loop.

Options:
- `--chunk-seconds 30`
- `--summary-minutes 5`
- `--out-dir sessions/<auto>`
- `--language en` (optional hint)
- `--keep-audio` (keep `.wav` chunks after transcription)
- `--model whisper-1` (transcription)
- `--summary-model <chat-model>` (summarization)
- `--device 0,1` (mix multiple audio devices)

Terminal output:
- prints new transcript lines as chunks complete
- prints summary updates on the 5-minute boundary

## Core logic
### Chunk processing
For each chunk file `outNNNNN.wav`:
1. Wait until file is stable (ffmpeg finished writing).
2. Transcribe via Whisper API.
3. Append to transcript + JSONL.
4. Mark chunk as processed (in-memory + persisted index file).
5. Optionally delete audio file.

### Summary processing (incremental)
Every `summary_minutes`:
1. Read transcript text since last summary.
2. Call summarizer with:
   - system: “You produce accurate meeting summaries…”
   - user: previous summary + new transcript block
3. Write updated `summary.md` with timestamp.

This avoids re-summarizing “all text so far” every time (keeps cost/context bounded).

## Proposed project structure (when we start coding)
```
livetranscription/
  pyproject.toml
  src/livetranscription/
    __init__.py
    cli.py
    ffmpeg_capture.py
    chunk_watcher.py
    transcribe.py
    summarize.py
    session_store.py
  SPEC.md
```

## Implementation checklist (next session)
1. Scaffold Python project (`pyproject.toml`, `src/` layout, CLI entrypoint).
2. Implement `devices` command:
   - run `ffmpeg -list_devices`
   - parse and print audio device list with indices
3. Implement `run` command:
   - spawn ffmpeg segmenter into session `chunks/`
   - watch for new `.wav` files
   - transcribe sequentially, append logs
4. Add 5‑minute summarizer loop (incremental summary).
5. Add graceful shutdown (Ctrl+C stops ffmpeg, flushes state).

## Open questions
- Do you want to transcribe **only system+mic mixed together**, or keep them as separate channels (more complex)?
- Do you want the summary format to include **action items** and **decisions**, or just a narrative paragraph?
