import { writable, derived } from 'svelte/store';

// Current session state
export const currentSession = writable(null);
export const sessionStatus = writable('disconnected'); // disconnected, connecting, created, prepared, recording, stopped

// Transcript data
// Each chunk has: { index, timestamp, text, segments: [{ speaker, text, start, end }] }
export const transcriptChunks = writable([]);
export const fullTranscript = derived(transcriptChunks, ($chunks) =>
  $chunks.map((c) => {
    if (c.segments && c.segments.length > 0) {
      return c.segments.map((s) => `[${c.timestamp}] [${s.speaker}] ${s.text}`).join('\n');
    }
    return `[${c.timestamp}] ${c.text}`;
  }).join('\n')
);

// Coaching alerts
export const coachingAlerts = writable([]);
export const activeAlerts = derived(coachingAlerts, ($alerts) =>
  $alerts.filter((a) => !a.dismissed)
);

// Summary
export const currentSummary = writable('');

// Meeting prep
export const meetingPrep = writable(null);
export const uncoveredTopics = derived(meetingPrep, ($prep) => {
  if (!$prep) return [];
  return $prep.talking_points.filter((tp) => !tp.mentioned);
});

// Audio devices
export const audioDevices = writable([]);

// Connection status
export const wsConnected = writable(false);

// Error state
export const lastError = writable(null);

// Helper functions
export function addTranscriptChunk(chunk) {
  transcriptChunks.update((chunks) => [...chunks, chunk]);
}

export function addCoachingAlert(alert) {
  coachingAlerts.update((alerts) => [alert, ...alerts]);
}

export function dismissAlert(alertId) {
  coachingAlerts.update((alerts) =>
    alerts.map((a) => (a.id === alertId ? { ...a, dismissed: true } : a))
  );
}

export function updateTalkingPointMentioned(topic) {
  meetingPrep.update((prep) => {
    if (!prep) return prep;
    return {
      ...prep,
      talking_points: prep.talking_points.map((tp) =>
        tp.topic.toLowerCase() === topic.toLowerCase()
          ? { ...tp, mentioned: true, mentioned_at: new Date().toISOString() }
          : tp
      ),
    };
  });
}

export function resetSession() {
  currentSession.set(null);
  sessionStatus.set('disconnected');
  transcriptChunks.set([]);
  coachingAlerts.set([]);
  currentSummary.set('');
  meetingPrep.set(null);
  wsConnected.set(false);
  lastError.set(null);
}
