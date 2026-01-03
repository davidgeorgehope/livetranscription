/**
 * WebSocket connection manager for real-time updates.
 */

export class WebSocketManager {
  constructor(sessionId) {
    this.sessionId = sessionId;
    this.ws = null;
    this.handlers = new Map();
    this.reconnectAttempts = 0;
    this.maxReconnectAttempts = 5;
    this.reconnectDelay = 1000;
  }

  connect() {
    const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    const host = window.location.host;
    const url = `${protocol}//${host}/ws/sessions/${this.sessionId}`;

    this.ws = new WebSocket(url);

    this.ws.onopen = () => {
      console.log('[WS] Connected');
      this.reconnectAttempts = 0;
      this.emit('connected', {});
    };

    this.ws.onmessage = (event) => {
      try {
        const message = JSON.parse(event.data);
        this.emit(message.type, message.data);
      } catch (e) {
        console.error('[WS] Failed to parse message:', e);
      }
    };

    this.ws.onclose = (event) => {
      console.log('[WS] Disconnected', event.code, event.reason);
      this.emit('disconnected', { code: event.code, reason: event.reason });

      // Attempt reconnection
      if (this.reconnectAttempts < this.maxReconnectAttempts) {
        this.reconnectAttempts++;
        const delay = this.reconnectDelay * Math.pow(2, this.reconnectAttempts - 1);
        console.log(`[WS] Reconnecting in ${delay}ms (attempt ${this.reconnectAttempts})`);
        setTimeout(() => this.connect(), delay);
      }
    };

    this.ws.onerror = (error) => {
      console.error('[WS] Error:', error);
      this.emit('error', { error });
    };
  }

  disconnect() {
    if (this.ws) {
      this.ws.close();
      this.ws = null;
    }
  }

  send(type, data = {}) {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify({ type, data }));
    }
  }

  on(event, handler) {
    if (!this.handlers.has(event)) {
      this.handlers.set(event, []);
    }
    this.handlers.get(event).push(handler);
  }

  off(event, handler) {
    if (this.handlers.has(event)) {
      const handlers = this.handlers.get(event);
      const index = handlers.indexOf(handler);
      if (index !== -1) {
        handlers.splice(index, 1);
      }
    }
  }

  emit(event, data) {
    if (this.handlers.has(event)) {
      for (const handler of this.handlers.get(event)) {
        try {
          handler(data);
        } catch (e) {
          console.error(`[WS] Handler error for ${event}:`, e);
        }
      }
    }

    // Also emit to wildcard handlers
    if (this.handlers.has('*')) {
      for (const handler of this.handlers.get('*')) {
        try {
          handler(event, data);
        } catch (e) {
          console.error('[WS] Wildcard handler error:', e);
        }
      }
    }
  }
}

// Ping to keep connection alive
export function startPing(wsManager, interval = 30000) {
  const pingInterval = setInterval(() => {
    wsManager.send('ping');
  }, interval);

  return () => clearInterval(pingInterval);
}
