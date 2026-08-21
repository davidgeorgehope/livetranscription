# livetranscription

Two stacks live here:

- **Cue (current):** native macOS app in `macos/`. Core Audio process tap, no BlackHole. Job is to hear a customer question and flash a short answer you can say immediately. See `macos/README.md`.
- **v1 (Python + BlackHole):** terminal/web coaching app below. Kept as reference.

See `SPEC.md` for the original MVP spec and the old BlackHole routing notes.

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
