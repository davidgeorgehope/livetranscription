# Cue — native live answers

Native macOS app. Listens to **system audio** with a Core Audio process tap (Zoom / Meet / browser) and to your **microphone** as a separate stream. No BlackHole, no Multi-Output Device, no ffmpeg.

Purpose: hear a customer question and put a **short, speakable answer** on screen in a few seconds.

## What it does

- Taps system audio via `CATapDescription` + private aggregate device (macOS 14.2+)
- Microphone as its own always-on stream ("Me"): a plain input tap with no voice processing, so Cue never ducks or re-gains the call. The engine rebuilds itself when the input device changes. On speakers the mic also hears the call; headphones keep "Me" clean
- Live Grok Voice STT (`wss://api.x.ai/v1/stt`, 16 kHz PCM, pinned to `grok-voice-transcribe-2.0` — the endpoint defaults to 1.0 if no model is named). Smart Turn (`smart_turn=0.6`, 2.5 s timeout) decides where a thought ends instead of a fixed silence timer, so a mid-sentence "um…" no longer splits a line. Up to 100 keyterms go with each session: a built-in product/security vocabulary plus proper nouns from your notes and this call's prep
- Meeting types: **Technical** (default — SA calls: architecture, security, integration; trusts `internal-docs/` and code above the playbook and marks internal-only detail), Sales, Interview, Internal
- **Context cards** (Technical and Internal): when someone names a customer, feature, system, or incident in passing, Cue retrieves what it already knows (prep, playbook, docs, past calls) and cards it — only if retrieval finds specific facts; otherwise nothing appears. Internal meetings also card any factual question nobody answered.
- One `grok-4.6` analyst pass per pause: detects questions (with a quick answer), coaching notes, commitments
- Grounds answers in `~/Library/Application Support/Cue/knowledge/` plus any folders you add. `product-docs/` (public cursor.com docs, `scripts/fetch_product_docs.py`) outranks internal docs and code for product behaviour; `playbook/` is how reps actually answer
- Replay a saved Me/Them transcript through the live pipeline: `scripts/fetch_call_transcript.py` pulls Gong calls from Databricks, then `CUE_REPLAY_FILE=<md> CUE_REPLAY_SPEED=4 CUE_REPLAY_TYPE=technical open -a ~/Applications/Cue.app` writes a `.report.md` of every card, coaching note, and commitment
- Paste product facts in Settings so it doesn't invent prices/SLAs
- **Prep docs per call**: drop `md/txt/pdf/docx` on the window (or `+ Add`). They outrank every other source for that call and are archived with its transcript. Anything written to `~/Library/Application Support/Cue/prep/inbox/` is attached the moment it lands. With `GROK_BOT_HOOK_URL`/`GROK_BOT_HOOK_KEY` in `.env`, the **Grok Bot brief** button fires your webhook-triggered automation with the call topic; the bot researches your threads and writes a one-page brief into that inbox via its local computer tool. Do it a few minutes before the call — the run is async and takes a while. **Listen also fires this automatically** (topic blank → the bot picks your current calendar meeting), silently; the brief attaches mid-call when it lands and is used from the next pass on. Skipped if a request is pending or a brief arrived in the last 30 min.
- **Call boundaries**: Cue watches which app holds the microphone (CoreAudio process objects — Zoom, Teams, Chrome for Meet; no permissions, no per-app code). Idle + an app takes the mic → "on a call? Listen" banner. Listening + the app lets go for 15 s → 30 s cancellable countdown, then Stop and the wrap. Fallback when there's no app signal: the brief's `meeting_start`/`meeting_end` lines (or its human `When:` line, via Apple's date detector) plus 90 s of silence past the scheduled end. Pure silence with neither signal only *suggests* stopping.
- **Post-call hand-off**: with `GROK_BOT_SUM_URL`/`GROK_BOT_SUM_KEY` in `.env`, the finished wrap (summary, commitments, follow-up draft, transcript excerpt, and the on-disk paths of the transcript and wrap so the bot can read the whole call) is POSTed to a second automation that does the summary and follow-ups. Automatic for calls over ~120 words; the wrap sheet has Send / Send again.

## Build / run

```bash
cd macos
./build-app.sh
open ~/Applications/Cue.app
```

App icon: Grok Imagine art in `Resources/AppIcon.icns`. Regenerate with `./scripts/generate_icon.sh` then rebuild.

First Listen: grant **Audio Capture / System Audio Recording** and **Microphone**.

Cmd+L starts/stops listening.

Needs an **xAI API key** (console.x.ai). Resolution order:

1. Settings field (saved to Keychain service `com.davidgeorgehope.cue`, account `xai`) — optional override
2. `XAI_API_KEY` process environment
3. `XAI_API_KEY` in repo-root `.env` (gitignored; see `.env.example`)

```bash
cp .env.example .env   # from repo root
# edit XAI_API_KEY=...
```

## Evals & playbook

Real customer questions come from Gong transcripts in Databricks (`dev.rperry.*`). Calls from the last 30 days are the held-out eval set; older calls feed the playbook. Each mined question is LLM-tagged `technical|commercial|process|other`; `--technical` on all three scripts restricts the loop to SA-type questions (older eval files without tags fall back to a keyword heuristic — re-mine to get real tags).

```bash
cd macos/scripts
python3 mine_call_questions.py --databricks --profile <p> --technical  # eval set: technical questions + what the SA/AE actually said
python3 prove_from_eval.py --technical --out /tmp/results.json   # replay through Cue, LLM-judge vs the human answer
python3 mine_playbook.py --results /tmp/results.json --profile <p> --technical  # failures → similar asks in older calls → playbook entries
```

`mine_playbook.py` writes dated, sourced Q&A markdown to `knowledge/playbook/` (no customer names). Re-run `prove_from_eval.py` afterwards to measure the delta. Playbook entries outrank other docs in retrieval and in the sourced prompt's trust order.

## Not this app

The Python + Svelte + BlackHole stack in the repo root is v1. Cue is the native replacement for the "answer the customer now" job.
