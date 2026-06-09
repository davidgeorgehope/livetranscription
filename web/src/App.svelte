<script>
  import { onMount, onDestroy } from 'svelte';
  import MeetingPrep from './components/MeetingPrep.svelte';
  import Transcript from './components/Transcript.svelte';
  import CoachingPanel from './components/CoachingPanel.svelte';
  import SessionControls from './components/SessionControls.svelte';
  import SessionList from './components/SessionList.svelte';
  import ChatPanel from './components/ChatPanel.svelte';
  import Settings from './components/Settings.svelte';
  import { WebSocketManager, startPing } from './lib/websocket.js';
  import * as api from './lib/api.js';
  import {
    appSettings,
    currentSession,
    sessionStatus,
    transcriptChunks,
    coachingAlerts,
    currentSummary,
    meetingPrep,
    audioDevices,
    deviceStatus,
    wsConnected,
    lastError,
    addTranscriptChunk,
    addCoachingAlert,
    resetSession,
  } from './lib/stores.js';

  let activeTab = 'current'; // 'current' | 'sessions' | 'chat' | 'settings'
  let view = 'prep'; // 'prep' | 'session'
  let selectedDevices = [];
  let wsManager = null;
  let stopPing = null;
  let loading = false;
  let autoRecordStatus = null;
  let deviceStatusInterval = null;

  onMount(async () => {
    const [devices, settings] = await Promise.all([
      loadDevices(),
      loadSettings(),
      loadAutoRecordStatus(),
      loadDeviceStatus(),
    ]);
    applySavedDefaults(settings, devices);
    // Poll device availability so the UI reflects mics being (un)plugged.
    deviceStatusInterval = setInterval(loadDeviceStatus, 5000);
  });

  onDestroy(() => {
    if (stopPing) stopPing();
    if (wsManager) wsManager.disconnect();
    if (deviceStatusInterval) clearInterval(deviceStatusInterval);
  });

  async function loadDevices() {
    try {
      const response = await api.listDevices();
      const devices = response.devices.filter((d) => d.type === 'audio');
      audioDevices.set(devices);
      return devices;
    } catch (e) {
      console.error('Failed to load devices:', e);
      lastError.set(e.message);
      return [];
    }
  }

  async function loadSettings() {
    try {
      const settings = await api.getSettings();
      appSettings.set(settings);
      return settings;
    } catch (e) {
      console.error('Failed to load settings:', e);
      lastError.set(e.message);
      return null;
    }
  }

  async function loadDeviceStatus() {
    try {
      const status = await api.getDeviceStatus();
      deviceStatus.set(status);
      return status;
    } catch (e) {
      console.error('Failed to load device status:', e);
      return null;
    }
  }

  async function loadAutoRecordStatus() {
    try {
      autoRecordStatus = await api.getAutoRecordStatus();
      return autoRecordStatus;
    } catch (e) {
      console.error('Failed to load auto-record status:', e);
      return null;
    }
  }

  function resolveSavedDeviceIndices(settings, devices) {
    if (!settings?.default_devices?.length || !devices?.length) {
      return [];
    }

    const byName = new Map(devices.map((device) => [device.name, device]));
    const byIndex = new Map(devices.map((device) => [device.index, device]));
    const resolved = [];

    for (const savedDevice of settings.default_devices) {
      const match = byName.get(savedDevice.name) || byIndex.get(savedDevice.index);
      if (match && !resolved.includes(match.index)) {
        resolved.push(match.index);
      }
    }

    return resolved;
  }

  function applySavedDefaults(settings, devices) {
    const savedDevices = resolveSavedDeviceIndices(settings, devices);
    if (savedDevices.length > 0) {
      selectedDevices = savedDevices;
    }
  }

  async function handleNewSession() {
    // Confirm the configured audio devices are present before recording.
    const status = await loadDeviceStatus();
    if (!status?.has_defaults) {
      lastError.set('No default audio devices configured. Set them in Settings first.');
      return;
    }
    if (!status.all_available) {
      lastError.set(
        `Waiting for audio devices: ${status.missing.join(', ')}. ` +
        `Recording will produce poor audio without them — connect them and try again.`
      );
      return;
    }

    loading = true;
    try {
      // Devices are resolved server-side from the saved defaults (matched by name).
      const session = await api.createSession({
        chunk_seconds: $appSettings?.chunk_seconds || 30,
        summary_minutes: $appSettings?.summary_minutes || 5,
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
      if (data.reason === 'max_duration_reached') {
        lastError.set(data.message || 'Session auto-stopped: maximum duration reached.');
      } else if (data.reason === 'meeting_ended_inactivity') {
        lastError.set(data.message || 'Session auto-stopped: meeting appears to have ended (no activity detected).');
      } else if (data.message) {
        lastError.set(data.message);
      }
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
    activeTab = 'current';
    handleNewSession();
  }

  async function handleSessionSelect(event) {
    const session = event.detail;
    loading = true;
    try {
      // Load session details
      const fullSession = await api.getSession(session.id);
      currentSession.set(fullSession);

      // Load transcript
      const transcript = await api.getTranscript(session.id);
      transcriptChunks.set(transcript.chunks);

      // Load summary
      const summaryData = await api.getSummary(session.id);
      currentSummary.set(summaryData.summary);

      // Load meeting prep if exists
      try {
        const prep = await api.getMeetingPrep(session.id);
        meetingPrep.set(prep);
      } catch (e) {
        // No meeting prep for this session
        meetingPrep.set(null);
      }

      // Load coaching history
      try {
        const coaching = await api.getCoachingHistory(session.id);
        coachingAlerts.set(coaching.alerts);
      } catch (e) {
        coachingAlerts.set([]);
      }

      sessionStatus.set(fullSession.status);
      view = 'session';
      activeTab = 'current';

      // Connect WebSocket if session is active (recording)
      if (fullSession.status === 'recording') {
        connectWebSocket(session.id);
      }
    } catch (e) {
      console.error('Failed to load session:', e);
      lastError.set(e.message);
    } finally {
      loading = false;
    }
  }

  async function handleSettingsSave(event) {
    loading = true;
    try {
      const settings = await api.saveSettings(event.detail);
      appSettings.set(settings);
      applySavedDefaults(settings, $audioDevices);
      await loadAutoRecordStatus();
      lastError.set(null);
    } catch (e) {
      console.error('Failed to save settings:', e);
      lastError.set(e.message);
    } finally {
      loading = false;
    }
  }

  async function handleAutoRecordCheck() {
    loading = true;
    try {
      autoRecordStatus = await api.checkAutoRecordNow();
      if (autoRecordStatus?.last_error) {
        lastError.set(autoRecordStatus.last_error);
      } else {
        lastError.set(null);
      }
    } catch (e) {
      console.error('Failed to check auto-record:', e);
      lastError.set(e.message);
    } finally {
      loading = false;
    }
  }
</script>

<div class="app">
  <header class="app-header">
    <h1>Live Transcription Coach</h1>
    <nav class="tabs">
      <button
        class="tab"
        class:active={activeTab === 'current'}
        on:click={() => activeTab = 'current'}
      >
        Current
      </button>
      <button
        class="tab"
        class:active={activeTab === 'sessions'}
        on:click={() => activeTab = 'sessions'}
      >
        Sessions
      </button>
      <button
        class="tab"
        class:active={activeTab === 'chat'}
        on:click={() => activeTab = 'chat'}
      >
        Chat
      </button>
      <button
        class="tab"
        class:active={activeTab === 'settings'}
        on:click={() => activeTab = 'settings'}
      >
        Settings
      </button>
    </nav>
  </header>

  {#if activeTab === 'current'}
  <SessionControls
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
            <li>Configure your audio devices in Settings (one-time)</li>
            <li>Click "New Session" to start</li>
            <li>Enter meeting prep context (optional)</li>
            <li>Start recording and get coached!</li>
          </ol>
          {#if $deviceStatus && !$deviceStatus.has_defaults}
            <p class="text-muted">No audio devices configured yet — head to Settings to pick your mic and system audio.</p>
          {:else if $deviceStatus && !$deviceStatus.all_available}
            <p class="text-muted">Waiting for audio devices: {$deviceStatus.missing.join(', ')}.</p>
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
  {:else if activeTab === 'sessions'}
  <main class="app-main">
    <SessionList on:select={handleSessionSelect} />
  </main>
  {:else if activeTab === 'chat'}
  <main class="app-main chat-main">
    <ChatPanel />
  </main>
  {:else if activeTab === 'settings'}
  <main class="app-main settings-main">
    <Settings
      bind:selectedDevices
      {autoRecordStatus}
      on:save={handleSettingsSave}
      on:checkAutoRecord={handleAutoRecordCheck}
    />
  </main>
  {/if}

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
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0.75rem 1rem;
    background: var(--color-surface-elevated);
    border-bottom: 1px solid var(--color-border);
  }

  .app-header h1 {
    margin: 0;
    font-size: 1.125rem;
    font-weight: 600;
  }

  .tabs {
    display: flex;
    gap: 0.25rem;
  }

  .tab {
    padding: 0.375rem 0.75rem;
    font-size: 0.75rem;
    font-weight: 500;
    background: transparent;
    border: 1px solid transparent;
    border-radius: 0.375rem;
    color: var(--color-text-muted);
    cursor: pointer;
    transition: all 0.15s;
  }

  .tab:hover {
    color: var(--color-text);
    background: var(--color-surface);
  }

  .tab.active {
    background: var(--color-primary);
    color: white;
    border-color: var(--color-primary);
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
    min-height: 0;
    overflow: hidden;
  }

  .settings-main {
    overflow-y: auto;
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

  .chat-main {
    padding: 1rem;
    max-width: 800px;
    margin: 0 auto;
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
