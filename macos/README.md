# Cue — native live answers

Native macOS app. Listens to **system audio** with a Core Audio process tap (Zoom / Meet / browser). No BlackHole, no Multi-Output Device, no ffmpeg.

Purpose: hear a customer question and put a **short, speakable answer** on screen in a few seconds.

## What it does

- Taps system audio via `CATapDescription` + private aggregate device (macOS 14.2+)
- Optional microphone mix if you want the room as well
- 8s speech-gated chunks → OpenAI `gpt-4o-mini-transcribe`
- Question detector → `gpt-4.1-mini` answer card
- Paste product facts in Settings so it doesn't invent prices/SLAs

## Build / run

```bash
cd macos
./build-app.sh
open Cue.app
```

First Listen: grant **Audio Capture / System Audio Recording** (and Microphone if you enabled it).

Cmd+Space starts/stops listening.

API key is stored in Keychain (`com.davidgeorgehope.cue`). It will also pick up `OPENAI_API_KEY` from the environment on first launch.

## Not this app

The Python + Svelte + BlackHole stack in the repo root is v1. Cue is the native replacement for the "answer the customer now" job.
