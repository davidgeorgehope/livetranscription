<script>
  import { createEventDispatcher } from 'svelte';
  import { appSettings, audioDevices } from '../lib/stores.js';

  const dispatch = createEventDispatcher();

  export let selectedDevices = [];
  export let autoRecordStatus = null;

  let chunkSeconds = 30;
  let summaryMinutes = 5;
  let autoRecordEnabled = false;
  let autoRecordStartWindowMinutes = 2;
  let autoRecordJoinGraceMinutes = 3;
  let autoRecordPollSeconds = 30;
  let autoRecordRequireMeetingLink = true;
  let autoRecordSkipPrivateEvents = true;
  let calendarCredentialsPath = '';
  let initialized = false;

  $: if ($appSettings && !initialized) {
    chunkSeconds = $appSettings.chunk_seconds || 30;
    summaryMinutes = $appSettings.summary_minutes || 5;
    autoRecordEnabled = Boolean($appSettings.auto_record_enabled);
    autoRecordStartWindowMinutes = $appSettings.auto_record_start_window_minutes || 2;
    autoRecordJoinGraceMinutes = $appSettings.auto_record_join_grace_minutes ?? 3;
    autoRecordPollSeconds = $appSettings.auto_record_poll_seconds || 30;
    autoRecordRequireMeetingLink = $appSettings.auto_record_require_meeting_link ?? true;
    autoRecordSkipPrivateEvents = $appSettings.auto_record_skip_private_events ?? true;
    calendarCredentialsPath = $appSettings.google_calendar_credentials_path || '';
    initialized = true;
  }

  $: selectedDeviceDetails = $audioDevices.filter((device) =>
    selectedDevices.includes(device.index)
  );
  $: savedDeviceNames = ($appSettings?.default_devices || []).map((device) => device.name);
  $: savedAt = $appSettings?.updated_at
    ? new Date($appSettings.updated_at).toLocaleString()
    : null;

  function toggleDevice(index) {
    if (selectedDevices.includes(index)) {
      selectedDevices = selectedDevices.filter((deviceIndex) => deviceIndex !== index);
    } else {
      selectedDevices = [...selectedDevices, index];
    }
  }

  function handleSave() {
    const defaultDevices = selectedDeviceDetails.length > 0
      ? selectedDeviceDetails.map((device) => ({
          index: device.index,
          name: device.name,
        }))
      : ($appSettings?.default_devices || []);

    dispatch('save', {
      default_devices: defaultDevices,
      chunk_seconds: Number(chunkSeconds),
      summary_minutes: Number(summaryMinutes),
      auto_record_enabled: autoRecordEnabled,
      auto_record_start_window_minutes: Number(autoRecordStartWindowMinutes),
      auto_record_join_grace_minutes: Number(autoRecordJoinGraceMinutes),
      auto_record_poll_seconds: Number(autoRecordPollSeconds),
      auto_record_require_meeting_link: autoRecordRequireMeetingLink,
      auto_record_skip_private_events: autoRecordSkipPrivateEvents,
      google_calendar_credentials_path: calendarCredentialsPath.trim() || null,
    });
  }

  function handleCheckNow() {
    dispatch('checkAutoRecord');
  }
</script>

<div class="settings-page">
  <div class="settings-header">
    <h2>Settings</h2>
    <p>Saved defaults are used when creating a new recording session.</p>
  </div>

  <section class="settings-section">
    <div class="section-heading">
      <div>
        <h3>Default Audio Devices</h3>
        <p>Pick the system audio and microphone inputs to mix for meetings.</p>
      </div>
      {#if selectedDeviceDetails.length > 0}
        <span class="badge info">{selectedDeviceDetails.length} selected</span>
      {/if}
    </div>

    <div class="device-list">
      {#if $audioDevices.length === 0}
        <div class="empty-state">No audio devices found.</div>
      {:else}
        {#each $audioDevices as device}
          <label class="device-row" class:selected={selectedDevices.includes(device.index)}>
            <input
              type="checkbox"
              checked={selectedDevices.includes(device.index)}
              on:change={() => toggleDevice(device.index)}
            />
            <span class="device-index">{device.index}</span>
            <span class="device-name">{device.name}</span>
            {#if savedDeviceNames.includes(device.name)}
              <span class="saved-pill">Saved</span>
            {/if}
          </label>
        {/each}
      {/if}
    </div>
  </section>

  <section class="settings-section">
    <div class="section-heading">
      <div>
        <h3>Session Defaults</h3>
        <p>These values apply to sessions created from the main view.</p>
      </div>
    </div>

    <div class="settings-grid">
      <label>
        Chunk length
        <input
          type="number"
          min="5"
          max="300"
          step="5"
          bind:value={chunkSeconds}
        />
      </label>
      <label>
        Summary cadence
        <input
          type="number"
          min="1"
          max="60"
          step="1"
          bind:value={summaryMinutes}
        />
      </label>
    </div>
  </section>

  <section class="settings-section">
    <div class="section-heading">
      <div>
        <h3>Automatic Recording</h3>
        <p>Use Google Calendar and saved audio devices to start sessions.</p>
      </div>
      <span class="badge" class:success={autoRecordEnabled} class:warning={!autoRecordEnabled}>
        {autoRecordEnabled ? 'Enabled' : 'Off'}
      </span>
    </div>

    <label class="toggle-row">
      <input type="checkbox" bind:checked={autoRecordEnabled} />
      <span>Start recording for calendar meetings</span>
    </label>

    <label>
      Credentials JSON path
      <input
        type="text"
        placeholder="/Users/dhope/Downloads/calendar-credentials.json"
        bind:value={calendarCredentialsPath}
      />
    </label>

    <div class="calendar-actions">
      <button class="secondary" on:click={handleCheckNow}>
        Check Now
      </button>
      <span>Use this once after saving the credentials path to authorize Google Calendar.</span>
    </div>

    <div class="settings-grid calendar-grid">
      <label>
        Start window
        <input
          type="number"
          min="1"
          max="30"
          step="1"
          bind:value={autoRecordStartWindowMinutes}
        />
      </label>
      <label>
        Join grace
        <input
          type="number"
          min="0"
          max="30"
          step="1"
          bind:value={autoRecordJoinGraceMinutes}
        />
      </label>
      <label>
        Poll interval
        <input
          type="number"
          min="10"
          max="300"
          step="5"
          bind:value={autoRecordPollSeconds}
        />
      </label>
    </div>

    <div class="option-list">
      <label class="toggle-row">
        <input type="checkbox" bind:checked={autoRecordRequireMeetingLink} />
        <span>Require a meeting link</span>
      </label>
      <label class="toggle-row">
        <input type="checkbox" bind:checked={autoRecordSkipPrivateEvents} />
        <span>Skip private events</span>
      </label>
    </div>

    <div class="watcher-status">
      <div>
        <span class="status-label">Watcher</span>
        <span class="status-value">{autoRecordStatus?.running ? 'Running' : 'Stopped'}</span>
      </div>
      {#if autoRecordStatus?.last_checked_at}
        <div>
          <span class="status-label">Last check</span>
          <span class="status-value">{new Date(autoRecordStatus.last_checked_at).toLocaleTimeString()}</span>
        </div>
      {/if}
      {#if autoRecordStatus?.last_started_event_title}
        <div>
          <span class="status-label">Last start</span>
          <span class="status-value">{autoRecordStatus.last_started_event_title}</span>
        </div>
      {/if}
      {#if autoRecordStatus?.last_error}
        <div class="status-error">{autoRecordStatus.last_error}</div>
      {/if}
    </div>
  </section>

  <div class="settings-actions">
    <button class="primary" on:click={handleSave}>
      Save Settings
    </button>
    {#if savedAt}
      <span class="saved-at">Last saved {savedAt}</span>
    {/if}
  </div>
</div>

<style>
  .settings-page {
    width: 100%;
    max-width: 920px;
    margin: 0 auto;
    padding: 1.5rem 1.5rem 3rem;
  }

  .settings-header {
    margin-bottom: 1.25rem;
  }

  .settings-header h2 {
    margin: 0 0 0.25rem 0;
    font-size: 1.25rem;
    font-weight: 600;
  }

  .settings-header p,
  .section-heading p {
    margin: 0;
    color: var(--color-text-muted);
    font-size: 0.875rem;
  }

  .settings-section {
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    padding: 1rem;
    margin-bottom: 1rem;
  }

  .section-heading {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 1rem;
    margin-bottom: 0.875rem;
  }

  .section-heading h3 {
    margin: 0 0 0.25rem 0;
    font-size: 0.95rem;
    font-weight: 600;
  }

  .device-list {
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
  }

  .device-row {
    display: grid;
    grid-template-columns: 18px 36px minmax(0, 1fr) auto;
    align-items: center;
    gap: 0.625rem;
    min-height: 42px;
    padding: 0.5rem 0.625rem;
    margin: 0;
    border: 1px solid var(--color-border);
    border-radius: var(--radius-sm);
    background: var(--color-bg);
    cursor: pointer;
  }

  .device-row.selected {
    border-color: var(--color-primary);
    background: rgba(59, 130, 246, 0.12);
  }

  .device-row input {
    width: 16px;
    height: 16px;
    margin: 0;
  }

  .device-index {
    color: var(--color-text-muted);
    font-family: var(--font-mono);
    font-size: 0.75rem;
  }

  .device-name {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    color: var(--color-text);
    font-size: 0.875rem;
  }

  .saved-pill {
    color: var(--color-success);
    font-size: 0.75rem;
    font-weight: 600;
  }

  .settings-grid {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 1rem;
  }

  .calendar-grid {
    grid-template-columns: repeat(3, minmax(0, 1fr));
    margin-top: 0.875rem;
  }

  .toggle-row {
    display: flex;
    align-items: center;
    gap: 0.625rem;
    min-height: 34px;
    margin: 0 0 0.75rem 0;
    color: var(--color-text);
    font-size: 0.875rem;
  }

  .toggle-row input {
    width: 16px;
    height: 16px;
    margin: 0;
  }

  .option-list {
    display: flex;
    gap: 1rem;
    margin-top: 0.875rem;
  }

  .calendar-actions {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    margin-top: 0.75rem;
  }

  .calendar-actions span {
    color: var(--color-text-muted);
    font-size: 0.75rem;
  }

  .watcher-status {
    display: flex;
    flex-wrap: wrap;
    gap: 0.75rem;
    margin-top: 0.875rem;
    padding-top: 0.875rem;
    border-top: 1px solid var(--color-border);
    font-size: 0.75rem;
  }

  .status-label {
    color: var(--color-text-muted);
    margin-right: 0.375rem;
  }

  .status-value {
    color: var(--color-text);
  }

  .status-error {
    width: 100%;
    color: var(--color-danger);
  }

  .settings-actions {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    padding-bottom: 1rem;
  }

  .saved-at {
    color: var(--color-text-muted);
    font-size: 0.75rem;
  }

  .empty-state {
    padding: 1rem;
    color: var(--color-text-muted);
    border: 1px dashed var(--color-border);
    border-radius: var(--radius-sm);
    font-size: 0.875rem;
  }

  @media (max-width: 700px) {
    .settings-page {
      padding: 1rem;
    }

    .settings-grid,
    .calendar-grid {
      grid-template-columns: 1fr;
    }

    .section-heading,
    .option-list,
    .calendar-actions,
    .settings-actions {
      align-items: stretch;
      flex-direction: column;
    }
  }
</style>
