<script>
  import { onMount, afterUpdate } from 'svelte';
  import { transcriptChunks, currentSummary, currentSession } from '../lib/stores.js';
  import * as api from '../lib/api.js';

  let transcriptContainer;
  let autoScroll = true;
  let showSummary = false;
  let regenerating = false;

  // Auto-scroll to bottom when new content arrives
  afterUpdate(() => {
    if (autoScroll && transcriptContainer) {
      transcriptContainer.scrollTop = transcriptContainer.scrollHeight;
    }
  });

  function handleScroll() {
    if (!transcriptContainer) return;

    const { scrollTop, scrollHeight, clientHeight } = transcriptContainer;
    const isNearBottom = scrollHeight - scrollTop - clientHeight < 100;
    autoScroll = isNearBottom;
  }

  function scrollToBottom() {
    if (transcriptContainer) {
      transcriptContainer.scrollTop = transcriptContainer.scrollHeight;
      autoScroll = true;
    }
  }

  function toggleSummary() {
    showSummary = !showSummary;
  }

  async function handleRegenerate() {
    if (!$currentSession || regenerating) return;

    regenerating = true;
    try {
      const result = await api.regenerateSummary($currentSession.id);
      currentSummary.set(result.summary);
    } catch (e) {
      console.error('Failed to regenerate summary:', e);
      alert('Failed to regenerate summary: ' + e.message);
    } finally {
      regenerating = false;
    }
  }

  // Generate a consistent color for each speaker
  const speakerColors = [
    'var(--color-speaker-1, #3b82f6)', // Blue
    'var(--color-speaker-2, #10b981)', // Green
    'var(--color-speaker-3, #f59e0b)', // Amber
    'var(--color-speaker-4, #8b5cf6)', // Purple
    'var(--color-speaker-5, #ec4899)', // Pink
  ];

  function getSpeakerColor(speaker) {
    // Extract number from "Speaker N" or use hash for other names
    const match = speaker.match(/(\d+)/);
    if (match) {
      const num = parseInt(match[1], 10) - 1;
      return speakerColors[num % speakerColors.length];
    }
    // Fallback: hash the name to get consistent color
    let hash = 0;
    for (let i = 0; i < speaker.length; i++) {
      hash = ((hash << 5) - hash) + speaker.charCodeAt(i);
      hash |= 0;
    }
    return speakerColors[Math.abs(hash) % speakerColors.length];
  }
</script>

<div class="transcript-panel">
  <div class="panel-header">
    <h3>Transcript</h3>
    <div class="header-actions">
      <button class="secondary small" on:click={toggleSummary}>
        {showSummary ? 'Hide' : 'Show'} Summary
      </button>
      {#if !autoScroll}
        <button class="secondary small" on:click={scrollToBottom}>
          Scroll to bottom
        </button>
      {/if}
    </div>
  </div>

  {#if showSummary && $currentSummary}
    <div class="summary-section">
      <div class="summary-header">
        <span class="badge info">Summary</span>
        <button
          class="secondary small regenerate-btn"
          on:click={handleRegenerate}
          disabled={regenerating}
          title="Regenerate summary from transcript"
        >
          {regenerating ? 'Regenerating...' : 'Regenerate'}
        </button>
      </div>
      <div class="summary-content">
        {@html $currentSummary.replace(/\n/g, '<br>')}
      </div>
    </div>
  {/if}

  <div
    class="transcript-content"
    bind:this={transcriptContainer}
    on:scroll={handleScroll}
  >
    {#if $transcriptChunks.length === 0}
      <div class="empty-state">
        <p>Transcript will appear here once recording starts...</p>
      </div>
    {:else}
      {#each $transcriptChunks as chunk (chunk.index)}
        <div class="transcript-chunk">
          <span class="timestamp">[{chunk.timestamp}]</span>
          {#if chunk.segments && chunk.segments.length > 0}
            <div class="segments">
              {#each chunk.segments as segment}
                <div class="segment">
                  <span class="speaker" style="color: {getSpeakerColor(segment.speaker)}">
                    [{segment.speaker}]
                  </span>
                  <span class="text">{segment.text}</span>
                </div>
              {/each}
            </div>
          {:else}
            <span class="text">{chunk.text}</span>
          {/if}
        </div>
      {/each}
    {/if}
  </div>

  {#if $transcriptChunks.length > 0}
    <div class="panel-footer">
      <span class="text-muted text-sm">
        {$transcriptChunks.length} chunks transcribed
      </span>
    </div>
  {/if}
</div>

<style>
  .transcript-panel {
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

  .header-actions {
    display: flex;
    gap: 0.5rem;
  }

  button.small {
    padding: 0.25rem 0.5rem;
    font-size: 0.75rem;
  }

  .summary-section {
    padding: 1rem;
    background: rgba(6, 182, 212, 0.1);
    border-bottom: 1px solid var(--color-border);
    max-height: 40%;
    overflow-y: auto;
    flex-shrink: 0;
  }

  .summary-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 0.5rem;
  }

  .regenerate-btn {
    font-size: 0.7rem;
    padding: 0.2rem 0.5rem;
  }

  .summary-content {
    font-size: 0.875rem;
    line-height: 1.6;
  }

  .transcript-content {
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
  }

  .transcript-chunk {
    margin-bottom: 0.75rem;
    line-height: 1.6;
  }

  .timestamp {
    font-family: var(--font-mono);
    font-size: 0.75rem;
    color: var(--color-text-muted);
    margin-right: 0.5rem;
  }

  .segments {
    display: inline;
  }

  .segment {
    display: block;
    margin-left: 0;
  }

  .segment:first-child {
    display: inline;
  }

  .segment:not(:first-child) {
    margin-top: 0.25rem;
    padding-left: calc(7ch + 0.5rem); /* Approximate timestamp width + margin */
  }

  .speaker {
    font-family: var(--font-mono);
    font-size: 0.8125rem;
    font-weight: 600;
    margin-right: 0.5rem;
  }

  .text {
    font-size: 0.9375rem;
  }

  .panel-footer {
    padding: 0.5rem 1rem;
    border-top: 1px solid var(--color-border);
    background: var(--color-surface-elevated);
  }
</style>
