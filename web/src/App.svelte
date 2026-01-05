<script>
  import { onMount, onDestroy } from 'svelte';
  import MeetingPrep from './components/MeetingPrep.svelte';
  import Transcript from './components/Transcript.svelte';
  import CoachingPanel from './components/CoachingPanel.svelte';
  import SessionControls from './components/SessionControls.svelte';
  import { WebSocketManager, startPing } from './lib/websocket.js';
  import * as api from './lib/api.js';
  import {
    currentSession,
    sessionStatus,
    transcriptChunks,
    coachingAlerts,
    currentSummary,
    meetingPrep,
    audioDevices,
    wsConnected,
    lastError,
    addTranscriptChunk,
    addCoachingAlert,
    resetSession,
  } from './lib/stores.js';

  let view = 'prep'; // 'prep' | 'session'
  let selectedDevices = [];
  let wsManager = null;
  let stopPing = null;
  let loading = false;

  onMount(async () => {
    await loadDevices();
  });

  onDestroy(() => {
    if (stopPing) stopPing();
    if (wsManager) wsManager.disconnect();
  });

  async function loadDevices() {
    try {
      const response = await api.listDevices();
      audioDevices.set(response.devices.filter((d) => d.type === 'audio'));
    } catch (e) {
      console.error('Failed to load devices:', e);
      lastError.set(e.message);
    }
  }

  async function handleNewSession() {
    if (selectedDevices.length === 0) {
      lastError.set('Please select at least one audio device');
      return;
    }

    loading = true;
    try {
      // Join device indices as comma-separated string for mixing
      const deviceString = selectedDevices.join(',');
      const session = await api.createSession({
        device_index: deviceString,
        chunk_seconds: 30,
        summary_minutes: 5,
      });
      currentSession.set(session);
      sessionStatus.set('created');
      view = 'prep';
      connectWebSocket(session.id);
    } catch (e) {
      console.error('Failed to create session:', e);
      lastError.set(e.message);
    } finally {
      loading = false;
    }
  }

  function connectWebSocket(sessionId) {
    if (wsManager) {
      wsManager.disconnect();
    }

    wsManager = new WebSocketManager(sessionId);

    wsManager.on('connected', () => {
      wsConnected.set(true);
    });

    wsManager.on('disconnected', () => {
      wsConnected.set(false);
    });

    wsManager.on('transcript_chunk', (data) => {
      addTranscriptChunk(data);
    });

    wsManager.on('coaching_alert', (data) => {
      addCoachingAlert(data);
    });

    wsManager.on('summary_update', (data) => {
      currentSummary.set(data.summary);
    });

    wsManager.on('session_status', (data) => {
      sessionStatus.set(data.status);
    });

    wsManager.connect();
    stopPing = startPing(wsManager);
  }

  async function handleMeetingPrepSubmit(event) {
    const prepData = event.detail;

    loading = true;
    try {
      const prep = await api.submitMeetingPrep($currentSession.id, prepData);
      meetingPrep.set(prep);
      sessionStatus.set('prepared');
      await startRecording();
    } catch (e) {
      console.error('Failed to submit meeting prep:', e);
      lastError.set(e.message);
    } finally {
      loading = false;
    }
  }

  async function handleMeetingPrepSkip() {
    view = 'session';
    await startRecording();
  }

  async function startRecording() {
    loading = true;
    try {
      const session = await api.startSession($currentSession.id);
      currentSession.set(session);
      sessionStatus.set('recording');
      view = 'session';
    } catch (e) {
      console.error('Failed to start recording:', e);
      lastError.set(e.message);
    } finally {
      loading = false;
    }
  }

  async function handleStart() {
    await startRecording();
  }

  async function handleStop() {
    loading = true;
    try {
      const session = await api.stopSession($currentSession.id);
      currentSession.set(session);
      sessionStatus.set('stopped');
    } catch (e) {
      console.error('Failed to stop recording:', e);
      lastError.set(e.message);
    } finally {
      loading = false;
    }
  }

  function handleNewSessionClick() {
    resetSession();
    view = 'prep';
    handleNewSession();
  }
</script>

<div class="app">
  <header class="app-header">
    <h1>Live Transcription Coach</h1>
  </header>

  <SessionControls
    bind:selectedDevices
    on:start={handleStart}
    on:stop={handleStop}
    on:new={handleNewSessionClick}
  />

  {#if $lastError}
    <div class="error-banner">
      <span>{$lastError}</span>
      <button on:click={() => lastError.set(null)}>&times;</button>
    </div>
  {/if}

  <main class="app-main">
    {#if !$currentSession}
      <div class="welcome-screen">
        <div class="welcome-content">
          <h2>Welcome to Live Transcription Coach</h2>
          <p>Get real-time coaching and suggestions during your meetings.</p>
          <ol class="steps">
            <li>Select an audio device above</li>
            <li>Click "New Session" to start</li>
            <li>Enter meeting prep context (optional)</li>
            <li>Start recording and get coached!</li>
          </ol>
          {#if $audioDevices.length === 0}
            <p class="text-muted">Loading audio devices...</p>
          {/if}
        </div>
      </div>
    {:else if view === 'prep' && $sessionStatus !== 'recording'}
      <MeetingPrep on:submit={handleMeetingPrepSubmit} on:skip={handleMeetingPrepSkip} />
    {:else}
      <div class="session-layout">
        <div class="transcript-area">
          <Transcript />
        </div>
        <div class="coaching-area">
          <CoachingPanel />
        </div>
      </div>
    {/if}
  </main>

  {#if loading}
    <div class="loading-overlay">
      <div class="loading-spinner"></div>
    </div>
  {/if}
</div>

<style>
  .app {
    display: flex;
    flex-direction: column;
    height: 100vh;
    background: var(--color-bg);
  }

  .app-header {
    padding: 0.75rem 1rem;
    background: var(--color-surface-elevated);
    border-bottom: 1px solid var(--color-border);
  }

  .app-header h1 {
    margin: 0;
    font-size: 1.125rem;
    font-weight: 600;
  }

  .error-banner {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0.5rem 1rem;
    background: rgba(239, 68, 68, 0.2);
    border-bottom: 1px solid var(--color-danger);
    color: var(--color-danger);
    font-size: 0.875rem;
  }

  .error-banner button {
    background: none;
    border: none;
    color: inherit;
    font-size: 1.25rem;
    cursor: pointer;
    padding: 0;
    line-height: 1;
  }

  .app-main {
    flex: 1;
    overflow: hidden;
  }

  .welcome-screen {
    display: flex;
    align-items: center;
    justify-content: center;
    height: 100%;
    padding: 2rem;
  }

  .welcome-content {
    max-width: 400px;
    text-align: center;
  }

  .welcome-content h2 {
    margin-bottom: 0.5rem;
  }

  .welcome-content p {
    color: var(--color-text-muted);
    margin-bottom: 1.5rem;
  }

  .steps {
    text-align: left;
    padding-left: 1.5rem;
    color: var(--color-text-muted);
  }

  .steps li {
    margin-bottom: 0.5rem;
  }

  .session-layout {
    display: grid;
    grid-template-columns: 1fr 350px;
    height: 100%;
    gap: 1px;
    background: var(--color-border);
  }

  .transcript-area {
    background: var(--color-bg);
    padding: 1rem;
    overflow: hidden;
  }

  .coaching-area {
    background: var(--color-bg);
    padding: 1rem;
    overflow: hidden;
  }

  .loading-overlay {
    position: fixed;
    top: 0;
    left: 0;
    right: 0;
    bottom: 0;
    background: rgba(0, 0, 0, 0.5);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 1000;
  }

  .loading-spinner {
    width: 40px;
    height: 40px;
    border: 3px solid var(--color-border);
    border-top-color: var(--color-primary);
    border-radius: 50%;
    animation: spin 1s linear infinite;
  }

  @keyframes spin {
    to {
      transform: rotate(360deg);
    }
  }

  @media (max-width: 800px) {
    .session-layout {
      grid-template-columns: 1fr;
      grid-template-rows: 1fr 300px;
    }
  }
</style>
