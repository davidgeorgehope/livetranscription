# Feature Ideas - Not Yet Implemented

Ideas from brainstorming session. Check off as implemented.

---

## Real-time Copilot Features

- [ ] **Live fact injection** - When they mention a number or claim, surface relevant info you know
- [ ] **Silence detection** - Alert when there's awkward silence or long pauses
- [ ] **"You've been talking for X minutes straight"** - More granular monologue detection
- [ ] **Sentiment trajectory** - Is this call going better or worse over time?

## Intelligence Capture

- [ ] **Commitment extraction** - "I'll send that over" / "let's schedule a follow-up" → automatic action items with speaker attribution
- [ ] **Decision log** - What was actually decided vs. just discussed
- [ ] **Quote extraction** - Capture gold quotes like "I wish Elastic could..." or "what we love about X is..."
- [ ] **Talk-time ratios** - Per-speaker metrics: are you listening or monologuing?

## Cross-Meeting Memory

- [ ] **Continuity prompts** - "This person said X in your last conversation"
- [ ] **Pattern detection** - What objections keep coming up across calls?
- [ ] **CRM/notes auto-populate** - Push structured data to external systems post-call

## Post-Call Artifacts

- [ ] **Draft follow-up email** - Generate before the call even ends
- [ ] **CRM notes generation** - Structured summary for pasting into Salesforce/HubSpot
- [ ] **Key takeaways doc** - Shareable meeting summary

## Meeting Type Templates

- [ ] **Competitive intel mode** - Different summarization/alerts for competitive calls
- [ ] **Discovery call mode** - Focus on uncovering needs, qualifying
- [ ] **Demo mode** - Track feature mentions, questions asked
- [ ] **Negotiation mode** - Track concessions, commitments, blockers
- [ ] **Internal sync mode** - Focus on decisions and action items

## UX Enhancements

- [ ] **"Rewind 30 seconds" hotkey** - Bookmark moments for later review
- [ ] **"We've discussed this before" detector** - Flag when meetings retread old ground
- [ ] **Vibe check classifier** - "Tire-kicker" vs. "serious buyer" signal

## Audio/Technical

- [ ] **Dual-stream audio** - Separate "you" vs "them" channels for cleaner diarization
- [ ] **Speaker identification** - Learn and remember specific voices across sessions

---

## Already Implemented

- [x] Web UI with real-time updates
- [x] Meeting prep interface (attendees, objectives, talking points, competitors)
- [x] Suggested questions (context-aware)
- [x] Objection handling prompts
- [x] "You haven't mentioned X yet" nudges (talking point tracking)
- [x] Competitor mention detection with context
- [x] Pace warnings (speaking too fast/slow)
- [x] Speaker diarization
- [x] Rolling summaries
- [x] Gemini 3 Pro for transcription
- [x] Gemini 3 Flash for coaching/summaries
