<script>
  import { createEventDispatcher, onMount } from 'svelte';
  import * as api from '../lib/api.js';

  const dispatch = createEventDispatcher();

  let sessions = [];
  let loading = true;
  let error = null;

  onMount(async () => {
    await loadSessions();
  });

  async function loadSessions() {
    loading = true;
    error = null;
    try {
      const response = await api.listSessions();
      sessions = response.sessions;
    } catch (e) {
      console.error('Failed to load sessions:', e);
      error = e.message;
    } finally {
      loading = false;
    }
  }

  function handleSelect(session) {
    dispatch('select', session);
  }

  function formatDate(dateStr) {
    const date = new Date(dateStr);
    return date.toLocaleDateString() + ' ' + date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  }

  function getStatusBadge(status) {
    const badges = {
      created: { label: 'Created', class: 'badge-info' },
      prepared: { label: 'Prepared', class: 'badge-info' },
      recording: { label: 'Recording', class: 'badge-success' },
      paused: { label: 'Paused', class: 'badge-warning' },
      stopped: { label: 'Stopped', class: 'badge-muted' },
    };
    return badges[status] || { label: status, class: 'badge-muted' };
  }
</script>

<div class="session-list">
  <div class="list-header">
    <h2>Past Sessions</h2>
    <button class="refresh-btn" on:click={loadSessions} disabled={loading}>
      {loading ? 'Loading...' : 'Refresh'}
    </button>
  </div>

  {#if error}
    <div class="error-message">{error}</div>
  {/if}

  {#if loading && sessions.length === 0}
    <div class="loading-state">Loading sessions...</div>
  {:else if sessions.length === 0}
    <div class="empty-state">
      <p>No sessions found.</p>
      <p class="text-muted">Create a new session to get started.</p>
    </div>
  {:else}
    <div class="sessions-grid">
      {#each sessions as session}
        <button
          type="button"
          class="session-card"
          on:click={() => handleSelect(session)}
        >
          <div class="session-header">
            <span class="session-id">{session.id}</span>
            <span class="badge {getStatusBadge(session.status).class}">
              {getStatusBadge(session.status).label}
            </span>
          </div>
          <div class="session-details">
            <div class="detail-row">
              <span class="label">Created:</span>
              <span class="value">{formatDate(session.created_at)}</span>
            </div>
            {#if session.chunks_processed > 0}
              <div class="detail-row">
                <span class="label">Chunks:</span>
                <span class="value">{session.chunks_processed}</span>
              </div>
            {/if}
            {#if session.meeting_prep}
              <div class="detail-row">
                <span class="label">Type:</span>
                <span class="value">{session.meeting_prep.meeting_type.replace('_', ' ')}</span>
              </div>
            {/if}
          </div>
        </button>
      {/each}
    </div>
  {/if}
</div>

<style>
  .session-list {
    height: 100%;
    display: flex;
    flex-direction: column;
    padding: 1rem;
    overflow: hidden;
  }

  .list-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 1rem;
  }

  .list-header h2 {
    margin: 0;
    font-size: 1.125rem;
  }

  .refresh-btn {
    padding: 0.375rem 0.75rem;
    font-size: 0.75rem;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 0.25rem;
    color: var(--color-text-muted);
    cursor: pointer;
    transition: all 0.15s;
  }

  .refresh-btn:hover:not(:disabled) {
    background: var(--color-surface-elevated);
    color: var(--color-text);
  }

  .refresh-btn:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  .error-message {
    padding: 0.75rem;
    background: rgba(239, 68, 68, 0.1);
    border: 1px solid var(--color-danger);
    border-radius: 0.375rem;
    color: var(--color-danger);
    margin-bottom: 1rem;
    font-size: 0.875rem;
  }

  .loading-state,
  .empty-state {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    color: var(--color-text-muted);
  }

  .empty-state p {
    margin: 0.25rem 0;
  }

  .sessions-grid {
    flex: 1;
    overflow-y: auto;
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
  }

  .session-card {
    display: block;
    width: 100%;
    text-align: left;
    padding: 0.75rem;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 0.5rem;
    cursor: pointer;
    transition: all 0.15s;
  }

  .session-card:hover {
    background: var(--color-surface-elevated);
    border-color: var(--color-primary);
  }

  .session-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 0.5rem;
  }

  .session-id {
    font-family: var(--font-mono);
    font-size: 0.875rem;
    font-weight: 500;
    color: var(--color-text);
  }

  .badge {
    padding: 0.125rem 0.5rem;
    font-size: 0.625rem;
    font-weight: 500;
    text-transform: uppercase;
    border-radius: 1rem;
  }

  .badge-info {
    background: rgba(59, 130, 246, 0.2);
    color: var(--color-info);
  }

  .badge-success {
    background: rgba(34, 197, 94, 0.2);
    color: var(--color-success);
  }

  .badge-warning {
    background: rgba(234, 179, 8, 0.2);
    color: var(--color-warning);
  }

  .badge-muted {
    background: rgba(156, 163, 175, 0.2);
    color: var(--color-text-muted);
  }

  .session-details {
    display: flex;
    flex-direction: column;
    gap: 0.25rem;
  }

  .detail-row {
    display: flex;
    gap: 0.5rem;
    font-size: 0.75rem;
  }

  .detail-row .label {
    color: var(--color-text-muted);
  }

  .detail-row .value {
    color: var(--color-text);
  }
</style>
