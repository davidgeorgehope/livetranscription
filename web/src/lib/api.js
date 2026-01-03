/**
 * API client for the live transcription backend.
 */

const BASE_URL = '/api';

async function request(path, options = {}) {
  const url = `${BASE_URL}${path}`;
  const response = await fetch(url, {
    headers: {
      'Content-Type': 'application/json',
      ...options.headers,
    },
    ...options,
  });

  if (!response.ok) {
    const error = await response.json().catch(() => ({ detail: response.statusText }));
    throw new Error(error.detail || 'Request failed');
  }

  return response.json();
}

// Device endpoints
export async function listDevices() {
  return request('/devices');
}

// Session endpoints
export async function listSessions() {
  return request('/sessions');
}

export async function createSession(data) {
  return request('/sessions', {
    method: 'POST',
    body: JSON.stringify(data),
  });
}

export async function getSession(sessionId) {
  return request(`/sessions/${sessionId}`);
}

export async function startSession(sessionId) {
  return request(`/sessions/${sessionId}/start`, {
    method: 'POST',
  });
}

export async function stopSession(sessionId) {
  return request(`/sessions/${sessionId}/stop`, {
    method: 'POST',
  });
}

// Meeting prep endpoints
export async function submitMeetingPrep(sessionId, data) {
  return request(`/sessions/${sessionId}/prep`, {
    method: 'POST',
    body: JSON.stringify(data),
  });
}

export async function getMeetingPrep(sessionId) {
  return request(`/sessions/${sessionId}/prep`);
}

// Transcript endpoints
export async function getTranscript(sessionId) {
  return request(`/sessions/${sessionId}/transcript`);
}

export async function getSummary(sessionId) {
  return request(`/sessions/${sessionId}/summary`);
}

export async function getCoachingHistory(sessionId) {
  return request(`/sessions/${sessionId}/coaching`);
}
