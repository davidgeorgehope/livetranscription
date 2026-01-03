<script>
  import { activeAlerts, uncoveredTopics, dismissAlert } from '../lib/stores.js';

  const alertTypeConfig = {
    objection: {
      label: 'Objection',
      color: 'warning',
      icon: '!',
    },
    suggested_question: {
      label: 'Question',
      color: 'info',
      icon: '?',
    },
    missing_topic: {
      label: 'Missing',
      color: 'danger',
      icon: '-',
    },
    competitor_mention: {
      label: 'Competitor',
      color: 'danger',
      icon: 'C',
    },
    pace_warning: {
      label: 'Pace',
      color: 'warning',
      icon: '>',
    },
    custom_reminder: {
      label: 'Reminder',
      color: 'info',
      icon: '*',
    },
  };

  function getConfig(alertType) {
    return alertTypeConfig[alertType] || { label: alertType, color: 'info', icon: '?' };
  }

  function handleDismiss(alertId) {
    dismissAlert(alertId);
  }

  function formatTime(timestamp) {
    if (!timestamp) return '';
    const date = new Date(timestamp);
    return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  }
</script>

<div class="coaching-panel">
  <div class="panel-header">
    <h3>Coaching</h3>
    {#if $activeAlerts.length > 0}
      <span class="alert-count">{$activeAlerts.length}</span>
    {/if}
  </div>

  <div class="panel-content">
    {#if $uncoveredTopics.length > 0}
      <div class="topics-checklist">
        <div class="section-header">
          <span class="section-title">Topics to Cover</span>
        </div>
        <ul class="topic-list">
          {#each $uncoveredTopics as topic}
            <li class="topic-item" class:high-priority={topic.priority === 1}>
              <span class="topic-checkbox"></span>
              <span class="topic-text">{topic.topic}</span>
              {#if topic.priority === 1}
                <span class="badge danger">HIGH</span>
              {/if}
            </li>
          {/each}
        </ul>
      </div>
    {/if}

    {#if $activeAlerts.length === 0 && $uncoveredTopics.length === 0}
      <div class="empty-state">
        <p>Coaching suggestions will appear here during the call...</p>
      </div>
    {:else}
      <div class="alerts-section">
        {#each $activeAlerts as alert (alert.id)}
          {@const config = getConfig(alert.alert_type)}
          <div class="alert-card {config.color}">
            <div class="alert-header">
              <span class="badge {config.color}">{config.label}</span>
              <span class="alert-time">{formatTime(alert.timestamp)}</span>
              <button
                class="dismiss-btn"
                on:click={() => handleDismiss(alert.id)}
                title="Dismiss"
              >
                &times;
              </button>
            </div>
            <div class="alert-content">
              {alert.content}
            </div>
            {#if alert.suggestion}
              <div class="alert-suggestion">
                <span class="suggestion-label">Suggestion:</span>
                {alert.suggestion}
              </div>
            {/if}
          </div>
        {/each}
      </div>
    {/if}
  </div>
</div>

<style>
  .coaching-panel {
    display: flex;
    flex-direction: column;
    height: 100%;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-lg);
    overflow: hidden;
  }

  .panel-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 0.75rem 1rem;
    border-bottom: 1px solid var(--color-border);
    background: var(--color-surface-elevated);
  }

  .panel-header h3 {
    margin: 0;
    font-size: 0.875rem;
    font-weight: 600;
  }

  .alert-count {
    background: var(--color-primary);
    color: white;
    font-size: 0.75rem;
    font-weight: 600;
    padding: 0.125rem 0.5rem;
    border-radius: 9999px;
    min-width: 1.5rem;
    text-align: center;
  }

  .panel-content {
    flex: 1;
    overflow-y: auto;
    padding: 1rem;
  }

  .empty-state {
    display: flex;
    align-items: center;
    justify-content: center;
    height: 100%;
    color: var(--color-text-muted);
    text-align: center;
  }

  .topics-checklist {
    margin-bottom: 1rem;
    padding-bottom: 1rem;
    border-bottom: 1px solid var(--color-border);
  }

  .section-header {
    margin-bottom: 0.5rem;
  }

  .section-title {
    font-size: 0.75rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--color-text-muted);
  }

  .topic-list {
    list-style: none;
    margin: 0;
    padding: 0;
  }

  .topic-item {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    padding: 0.375rem 0;
    font-size: 0.875rem;
  }

  .topic-item.high-priority {
    font-weight: 500;
  }

  .topic-checkbox {
    width: 14px;
    height: 14px;
    border: 2px solid var(--color-border);
    border-radius: 3px;
    flex-shrink: 0;
  }

  .topic-text {
    flex: 1;
  }

  .alerts-section {
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
  }

  .alert-card {
    background: var(--color-surface-elevated);
    border-radius: var(--radius-md);
    padding: 0.75rem;
    border-left: 3px solid;
  }

  .alert-card.warning {
    border-left-color: var(--color-warning);
  }

  .alert-card.info {
    border-left-color: var(--color-info);
  }

  .alert-card.danger {
    border-left-color: var(--color-danger);
  }

  .alert-card.success {
    border-left-color: var(--color-success);
  }

  .alert-header {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    margin-bottom: 0.5rem;
  }

  .alert-time {
    font-size: 0.75rem;
    color: var(--color-text-muted);
    margin-left: auto;
  }

  .dismiss-btn {
    background: none;
    border: none;
    color: var(--color-text-muted);
    font-size: 1.25rem;
    line-height: 1;
    padding: 0;
    cursor: pointer;
    opacity: 0.7;
  }

  .dismiss-btn:hover {
    opacity: 1;
    color: var(--color-text);
  }

  .alert-content {
    font-size: 0.875rem;
    line-height: 1.5;
  }

  .alert-suggestion {
    margin-top: 0.5rem;
    padding-top: 0.5rem;
    border-top: 1px solid var(--color-border);
    font-size: 0.8125rem;
    color: var(--color-text-muted);
  }

  .suggestion-label {
    font-weight: 500;
    color: var(--color-text);
  }
</style>
