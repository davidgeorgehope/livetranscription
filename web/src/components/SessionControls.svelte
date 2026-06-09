<script>
  import { createEventDispatcher } from 'svelte';
  import { sessionStatus, currentSession, wsConnected, deviceStatus } from '../lib/stores.js';

  const dispatch = createEventDispatcher();

  $: isRecording = $sessionStatus === 'recording';
  $: hasDefaults = Boolean($deviceStatus?.has_defaults);
  $: devicesReady = Boolean($deviceStatus?.all_available);
  $: configuredDevices = $deviceStatus?.configured || [];
  $: canStart = $currentSession && !isRecording && devicesReady;
  $: canStop = isRecording;

  function handleStart() {
    dispatch('start');
  }

  function handleStop() {
    dispatch('stop');
  }

  function handleNewSession() {
    dispatch('new');
  }

  function getStatusLabel(status) {
    const labels = {
      disconnected: 'Disconnected',
      connecting: 'Connecting...',
      created: 'Ready',
      prepared: 'Prepared',
      recording: 'Recording',
      stopped: 'Stopped',
    };
    return labels[status] || status;
  }

  function getStatusColor(status) {
    const colors = {
      disconnected: 'text-muted',
      connecting: 'warning',
      created: 'info',
      prepared: 'info',
      recording: 'success',
      stopped: 'text-muted',
    };
    return colors[status] || 'text-muted';
  }
</script>

<div class="session-controls">
  <div class="control-row">
    <div class="status-section">
      <div class="status-indicator" class:connected={$wsConnected} class:recording={isRecording}></div>
      <span class="status-text {getStatusColor($sessionStatus)}">
        {getStatusLabel($sessionStatus)}
      </span>
      {#if isRecording}
        <span class="recording-pulse"></span>
      {/if}
    </div>

    <div class="device-select">
      <span class="device-label">Audio:</span>
      <div class="device-chips">
        {#if !$deviceStatus}
          <span class="no-devices">Checking devices...</span>
        {:else if !hasDefaults}
          <span class="no-devices">No devices configured — set them in Settings</span>
        {:else}
          {#each configuredDevices as device}
            <span
              class="device-chip"
              class:available={device.available}
              class:missing={!device.available}
              title={device.available ? 'Connected' : 'Not connected'}
            >
              <span class="device-dot"></span>
              {device.name}
            </span>
          {/each}
        {/if}
      </div>
    </div>

    <div class="control-buttons">
      {#if !$currentSession}
        <button class="primary" on:click={handleNewSession} disabled={!devicesReady}>
          New Session
        </button>
      {:else if isRecording}
        <button class="danger" on:click={handleStop}>
          Stop Recording
        </button>
      {:else}
        <button class="success" on:click={handleStart} disabled={!canStart}>
          Start Recording
        </button>
      {/if}
    </div>
  </div>

  {#if hasDefaults && !devicesReady}
    <div class="device-warning">
      Waiting for audio devices: {($deviceStatus?.missing || []).join(', ')}. Recording is
      disabled until they're connected to avoid poor-quality audio.
    </div>
  {/if}

  {#if $currentSession}
    <div class="session-info">
      <span class="info-label">Session:</span>
      <span class="info-value font-mono">{$currentSession.id}</span>
      {#if $currentSession.chunks_processed > 0}
        <span class="info-divider">|</span>
        <span class="info-value">{$currentSession.chunks_processed} chunks</span>
      {/if}
    </div>
  {/if}
</div>

<style>
  .session-controls {
    background: var(--color-surface);
    border-bottom: 1px solid var(--color-border);
    padding: 0.75rem 1rem;
  }

  .control-row {
    display: flex;
    align-items: center;
    gap: 1rem;
  }

  .status-section {
    display: flex;
    align-items: center;
    gap: 0.5rem;
  }

  .status-indicator {
    width: 10px;
    height: 10px;
    border-radius: 50%;
    background: var(--color-text-muted);
    transition: background-color 0.2s;
  }

  .status-indicator.connected {
    background: var(--color-info);
  }

  .status-indicator.recording {
    background: var(--color-success);
    animation: pulse 1.5s infinite;
  }

  @keyframes pulse {
    0%, 100% {
      opacity: 1;
    }
    50% {
      opacity: 0.5;
    }
  }

  .status-text {
    font-size: 0.875rem;
    font-weight: 500;
  }

  .status-text.warning {
    color: var(--color-warning);
  }

  .status-text.info {
    color: var(--color-info);
  }

  .status-text.success {
    color: var(--color-success);
  }

  .recording-pulse {
    width: 8px;
    height: 8px;
    background: var(--color-danger);
    border-radius: 50%;
    animation: pulse 1s infinite;
  }

  .device-select {
    flex: 1;
    display: flex;
    align-items: center;
    gap: 0.5rem;
    overflow-x: auto;
  }

  .device-label {
    font-size: 0.75rem;
    color: var(--color-text-muted);
    white-space: nowrap;
  }

  .device-chips {
    display: flex;
    gap: 0.375rem;
    flex-wrap: wrap;
  }

  .device-chip {
    display: inline-flex;
    align-items: center;
    gap: 0.375rem;
    padding: 0.25rem 0.5rem;
    font-size: 0.75rem;
    border: 1px solid var(--color-border);
    border-radius: 1rem;
    background: var(--color-surface);
    color: var(--color-text-muted);
    white-space: nowrap;
    user-select: none;
  }

  .device-dot {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    background: var(--color-text-muted);
  }

  .device-chip.available {
    border-color: var(--color-success);
    color: var(--color-text);
  }

  .device-chip.available .device-dot {
    background: var(--color-success);
  }

  .device-chip.missing {
    border-color: var(--color-danger);
    color: var(--color-danger);
  }

  .device-chip.missing .device-dot {
    background: var(--color-danger);
  }

  .device-warning {
    margin-top: 0.5rem;
    padding: 0.375rem 0.625rem;
    font-size: 0.75rem;
    color: var(--color-danger);
    background: rgba(239, 68, 68, 0.08);
    border: 1px solid var(--color-danger);
    border-radius: var(--radius-sm);
  }

  .no-devices {
    font-size: 0.75rem;
    color: var(--color-text-muted);
    font-style: italic;
  }

  .control-buttons {
    display: flex;
    gap: 0.5rem;
  }

  .session-info {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    margin-top: 0.5rem;
    font-size: 0.75rem;
  }

  .info-label {
    color: var(--color-text-muted);
  }

  .info-value {
    color: var(--color-text);
  }

  .info-divider {
    color: var(--color-border);
  }

  .sr-only {
    position: absolute;
    width: 1px;
    height: 1px;
    padding: 0;
    margin: -1px;
    overflow: hidden;
    clip: rect(0, 0, 0, 0);
    border: 0;
  }
</style>
