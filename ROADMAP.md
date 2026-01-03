# Feature Roadmap

Prioritized feature roadmap for the Live Transcription + Coaching app, optimized for Product Marketing workflows.

## What's Already Built

- [x] Web UI with real-time updates (Svelte + FastAPI + WebSocket)
- [x] Meeting prep interface (attendees, objectives, talking points, competitors)
- [x] Suggested questions (context-aware)
- [x] Objection handling prompts
- [x] "You haven't mentioned X yet" nudges (talking point tracking)
- [x] Competitor mention detection with context
- [x] Pace warnings (speaking too fast/slow)
- [x] Speaker diarization (Gemini 3 Pro)
- [x] Rolling summaries (Gemini 3 Flash)
- [x] Gemini 3 Pro for transcription
- [x] Gemini 3 Flash for coaching/summaries

---

## Phase 1: Quick Wins

Build on existing infrastructure with minimal changes.

### 1.1 Talk-Time Ratios
**Value:** Know if you're listening vs monologuing
**Effort:** Low

- Calculate speaking time per speaker from diarization data
- Add to WebSocket broadcast as real-time stat
- Display in UI as simple bar or percentage

**Files:** `server.py`, `Transcript.svelte`

### 1.2 Enhanced Monologue Detection
**Value:** Real-time feedback on speaking patterns
**Effort:** Low

- Use diarization to detect when YOU specifically have been talking too long
- More accurate than current silence-gap detection

**Files:** `coaching.py`

---

## Phase 2: Intelligence Capture

Core PMM value - capturing customer voice and commitments.

### 2.1 Quote Extraction ⭐ (Next Up)
**Value:** Capture customer voice for messaging, competitive positioning
**Effort:** Medium

Capture quotes like:
- "I wish Elastic could..."
- "What we love about X is..."
- "Our pain point is..."
- "Compared to [competitor], you..."

**Implementation:**
- Add `quotes` section to coaching prompt
- New `AlertType.NOTABLE_QUOTE`
- Store in `coaching.jsonl` with speaker attribution
- Display in UI with copy button

**Files:** `session_store.py`, `coaching.py`, `CoachingPanel.svelte`

### 2.2 Commitment/Action Item Extraction ⭐ (Next Up)
**Value:** Never miss a follow-up
**Effort:** Medium (same LLM pass as quotes)

Extract commitments:
- "I'll send that over"
- "Let's schedule a follow-up"
- "Can you share the pricing?"
- "We need to loop in [person]"

**Implementation:**
- Add `commitments` section to coaching prompt
- New `AlertType.ACTION_ITEM`
- Include speaker + what was committed
- Surface in post-call summary

**Files:** `session_store.py`, `coaching.py`, `summarize.py`

### 2.3 Decision Log
**Value:** Distinguish what was decided vs just discussed
**Effort:** Low

**Implementation:**
- Update summary prompt to explicitly separate:
  - Decisions made
  - Topics discussed (no decision)
  - Open questions
  - Action items

**Files:** `summarize.py`

---

## Phase 3: Post-Call Artifacts

Save time after calls with auto-generated outputs.

### 3.1 Follow-Up Email Draft
**Value:** Draft email ready before you hang up
**Effort:** Medium

Generate at session end:
- Thank you for the time
- Key points discussed
- Action items (who owes what)
- Proposed next steps

**Implementation:**
- New endpoint `POST /api/sessions/{id}/generate-email`
- New `artifacts.py` module
- UI button to generate + copy

**Files:** `server.py`, `artifacts.py` (new), `PostCallArtifacts.svelte` (new)

### 3.2 CRM Notes
**Value:** Structured output for Salesforce/HubSpot
**Effort:** Low (variant of follow-up email)

Generate:
- Meeting date/attendees
- Key topics (bullets)
- Decisions
- Next steps
- Competitor mentions (if any)

**Files:** `server.py`, `artifacts.py`

---

## Phase 4: Meeting Type Templates

Different meetings need different focus.

### 4.1 Mode-Specific Coaching
**Value:** Tailored coaching per meeting type
**Effort:** Medium

| Mode | Focus |
|------|-------|
| Discovery | Qualifying questions, needs uncovering |
| Demo | Feature mentions, questions asked, objections |
| Competitive Intel | Competitor mentions with context, positioning |
| Internal Sync | Decisions, action items, blockers |
| Customer Success | Health signals, expansion opportunities |

**Implementation:**
- Enhance `MeetingType` enum
- Mode-specific coaching prompts
- Mode-specific post-call artifact formats

**Files:** `session_store.py`, `meeting_prep.py`, `coaching.py`

---

## Future Phases

| Feature | Description | Why Later |
|---------|-------------|-----------|
| Cross-meeting memory | "This person said X in your last conversation" | Requires persistent DB |
| Pattern detection | What objections keep coming up across calls? | Needs cross-session analysis |
| CRM auto-populate | Push structured data to Salesforce/HubSpot | API integration complexity |
| Sentiment trajectory | Is this call going better or worse over time? | Nice-to-have |
| Live fact injection | Surface relevant info when they mention claims | Requires knowledge base |
| Dual-stream audio | Separate "you" vs "them" channels | Hardware-dependent |
| Speaker identification | Remember specific voices across sessions | Voice fingerprinting |
| "Discussed before" detector | Flag when meetings retread old ground | Cross-session search |
| Vibe check classifier | "Tire-kicker" vs "serious buyer" signal | Nice-to-have |
| Rewind hotkey | Bookmark moments for later review | UX feature |

---

## Technical Notes

### Models Used
- **Transcription:** `gemini-3-pro-preview` (with speaker diarization)
- **Coaching/Summaries:** `gemini-3-flash-preview`

### Environment
- Only `GOOGLE_API_KEY` needed (no OpenAI dependency)
- macOS-only (uses AVFoundation for audio capture)

### Architecture
```
Audio (ffmpeg) → 30s WAV chunks → Gemini transcription → Coaching analysis → WebSocket → UI
                                                      ↓
                                            JSONL persistence
```
