<script>
  import { afterUpdate } from 'svelte';
  import { chatMessages, addChatMessage, clearChatMessages, currentSession, fullTranscript, currentSummary } from '../lib/stores.js';
  import * as api from '../lib/api.js';

  let messageInput = '';
  let chatContainer;
  let sending = false;

  afterUpdate(() => {
    if (chatContainer) {
      chatContainer.scrollTop = chatContainer.scrollHeight;
    }
  });

  async function handleSend() {
    if (!messageInput.trim() || sending) return;
    if (!$currentSession) {
      return;
    }

    const userMessage = messageInput.trim();
    messageInput = '';

    addChatMessage({
      role: 'user',
      content: userMessage,
    });

    sending = true;
    try {
      // Build conversation history for context
      const history = $chatMessages.slice(-10).map(m => ({
        role: m.role,
        content: m.content,
      }));

      const response = await api.sendChatMessage($currentSession.id, userMessage, history);

      addChatMessage({
        role: 'assistant',
        content: response.response,
      });
    } catch (e) {
      console.error('Chat error:', e);
      addChatMessage({
        role: 'assistant',
        content: `Sorry, I encountered an error: ${e.message}`,
      });
    } finally {
      sending = false;
    }
  }

  function handleKeydown(event) {
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault();
      handleSend();
    }
  }

  function handleClear() {
    clearChatMessages();
  }

  function sendSuggestion(text) {
    if (!$currentSession) return;
    messageInput = text;
    handleSend();
  }

  // Format session date for display
  function formatSessionDate(session) {
    if (!session?.created_at) return '';
    const date = new Date(session.created_at);
    return date.toLocaleDateString() + ' ' + date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  }
</script>

<div class="chat-panel">
  <div class="panel-header">
    <div class="header-left">
      <h3>Chat</h3>
      {#if $currentSession}
        <span class="session-badge">
          Session: {formatSessionDate($currentSession)}
        </span>
      {/if}
    </div>
    <div class="header-actions">
      {#if $chatMessages.length > 0}
        <button class="secondary small" on:click={handleClear}>
          Clear
        </button>
      {/if}
    </div>
  </div>

  {#if !$currentSession}
    <div class="no-session-state">
      <div class="no-session-content">
        <svg class="icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"></path>
        </svg>
        <h4>No Session Selected</h4>
        <p>To chat about a conversation, first:</p>
        <ol>
          <li>Go to the <strong>Sessions</strong> tab</li>
          <li>Click on a past session to load it</li>
          <li>Come back here to ask questions</li>
        </ol>
        <p class="hint">Or start a new recording in the <strong>Current</strong> tab</p>
      </div>
    </div>
  {:else}
    <div class="chat-content" bind:this={chatContainer}>
      {#if $chatMessages.length === 0}
        <div class="empty-state">
          <p>Ask questions about the conversation</p>
          <div class="suggestions">
            <button class="suggestion" on:click={() => sendSuggestion('What were the main points discussed?')}>
              Main points?
            </button>
            <button class="suggestion" on:click={() => sendSuggestion('What action items were mentioned?')}>
              Action items?
            </button>
            <button class="suggestion" on:click={() => sendSuggestion('What questions were asked?')}>
              Questions asked?
            </button>
            <button class="suggestion" on:click={() => sendSuggestion('Summarize the key decisions made')}>
              Key decisions?
            </button>
          </div>
        </div>
      {:else}
        {#each $chatMessages as message}
          <div class="message" class:user={message.role === 'user'} class:assistant={message.role === 'assistant'}>
            <div class="message-header">
              <span class="role">{message.role === 'user' ? 'You' : 'Assistant'}</span>
            </div>
            <div class="message-content">
              {@html message.content.replace(/\n/g, '<br>')}
            </div>
          </div>
        {/each}
        {#if sending}
          <div class="message assistant">
            <div class="message-header">
              <span class="role">Assistant</span>
            </div>
            <div class="message-content typing">
              <span class="dot"></span>
              <span class="dot"></span>
              <span class="dot"></span>
            </div>
          </div>
        {/if}
      {/if}
    </div>

    <div class="chat-input">
      <textarea
        bind:value={messageInput}
        on:keydown={handleKeydown}
        placeholder="Ask about the conversation..."
        rows="2"
        disabled={sending}
      ></textarea>
      <button class="primary" on:click={handleSend} disabled={sending || !messageInput.trim()}>
        {sending ? '...' : 'Send'}
      </button>
    </div>
  {/if}
</div>

<style>
  .chat-panel {
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

  .header-left {
    display: flex;
    align-items: center;
    gap: 0.75rem;
  }

  .panel-header h3 {
    margin: 0;
    font-size: 0.875rem;
    font-weight: 600;
  }

  .session-badge {
    font-size: 0.75rem;
    padding: 0.25rem 0.5rem;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    color: var(--color-text-muted);
  }

  .header-actions {
    display: flex;
    gap: 0.5rem;
  }

  button.small {
    padding: 0.25rem 0.5rem;
    font-size: 0.75rem;
  }

  .no-session-state {
    flex: 1;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 2rem;
  }

  .no-session-content {
    text-align: center;
    max-width: 300px;
  }

  .no-session-content .icon {
    width: 48px;
    height: 48px;
    margin-bottom: 1rem;
    color: var(--color-text-muted);
  }

  .no-session-content h4 {
    margin: 0 0 0.5rem;
    font-size: 1rem;
  }

  .no-session-content p {
    color: var(--color-text-muted);
    font-size: 0.875rem;
    margin: 0.5rem 0;
  }

  .no-session-content ol {
    text-align: left;
    padding-left: 1.5rem;
    margin: 1rem 0;
    color: var(--color-text-muted);
    font-size: 0.875rem;
  }

  .no-session-content ol li {
    margin-bottom: 0.5rem;
  }

  .no-session-content .hint {
    font-size: 0.75rem;
    margin-top: 1rem;
  }

  .chat-content {
    flex: 1;
    overflow-y: auto;
    padding: 1rem;
  }

  .empty-state {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    height: 100%;
    color: var(--color-text-muted);
    text-align: center;
  }

  .suggestions {
    display: flex;
    flex-wrap: wrap;
    gap: 0.5rem;
    margin-top: 1rem;
    justify-content: center;
  }

  .suggestion {
    padding: 0.5rem 0.75rem;
    font-size: 0.75rem;
    background: var(--color-surface-elevated);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    color: var(--color-text);
    cursor: pointer;
    transition: all 0.15s;
  }

  .suggestion:hover {
    background: var(--color-primary);
    color: white;
    border-color: var(--color-primary);
  }

  .message {
    margin-bottom: 1rem;
    padding: 0.75rem;
    border-radius: var(--radius-md);
  }

  .message.user {
    background: var(--color-primary);
    color: white;
    margin-left: 2rem;
  }

  .message.assistant {
    background: var(--color-surface-elevated);
    margin-right: 2rem;
  }

  .message-header {
    font-size: 0.75rem;
    font-weight: 600;
    margin-bottom: 0.25rem;
    opacity: 0.8;
  }

  .message-content {
    font-size: 0.875rem;
    line-height: 1.5;
  }

  .typing {
    display: flex;
    gap: 0.25rem;
    padding: 0.25rem 0;
  }

  .dot {
    width: 6px;
    height: 6px;
    background: var(--color-text-muted);
    border-radius: 50%;
    animation: bounce 1.4s infinite ease-in-out both;
  }

  .dot:nth-child(1) {
    animation-delay: -0.32s;
  }

  .dot:nth-child(2) {
    animation-delay: -0.16s;
  }

  @keyframes bounce {
    0%, 80%, 100% {
      transform: scale(0);
    }
    40% {
      transform: scale(1);
    }
  }

  .chat-input {
    display: flex;
    gap: 0.5rem;
    padding: 0.75rem;
    border-top: 1px solid var(--color-border);
    background: var(--color-surface-elevated);
  }

  .chat-input textarea {
    flex: 1;
    padding: 0.5rem;
    font-size: 0.875rem;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
    color: var(--color-text);
    resize: none;
    font-family: inherit;
  }

  .chat-input textarea:focus {
    outline: none;
    border-color: var(--color-primary);
  }

  .chat-input textarea:disabled {
    opacity: 0.6;
  }

  .chat-input button {
    padding: 0.5rem 1rem;
    font-size: 0.875rem;
    align-self: flex-end;
  }

  .chat-input button:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }
</style>
