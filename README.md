# livetranscription

Local macOS terminal app that captures audio, transcribes with OpenAI Whisper (chunked), and produces a rolling 5‑minute summary.

See `SPEC.md` for the full MVP spec and macOS BlackHole routing notes.

## Requirements
- macOS
- `ffmpeg` (`brew install ffmpeg`)
- Python 3.9+ (use `python3`)
- BlackHole installed (for system audio capture)
- `OPENAI_API_KEY` set in your shell env

## Install (dev)
```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -U pip
pip install -e .
```

## List devices
```bash
livetranscribe devices
```

## Run
Record + transcribe:
```bash
livetranscribe run --device 0
```

Mix two audio devices (common for system audio + mic):
```bash
livetranscribe run --device 0,1
```

Tips:
- Use headphones to avoid feedback/echo into the mic.
- To capture system audio *and* still hear it, route output to a **Multi-Output Device** that includes your speakers/headphones + BlackHole (see `SPEC.md`).

## Outputs
Each run writes a folder under `sessions/` containing:
- `transcript.txt` (append-only)
- `transcript.jsonl` (chunk-by-chunk metadata)
- `summary.md` (updated every 5 minutes)
- `ffmpeg.log`
- `state.json`
- `failed_chunks/` (audio chunks that failed transcription)
