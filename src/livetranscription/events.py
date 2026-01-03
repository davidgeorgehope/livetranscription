"""
Event bus for internal pub/sub communication between components.

Enables decoupled communication between the transcription engine,
coaching module, and web layer.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Callable, Coroutine

# Event type constants
EVENT_CHUNK_TRANSCRIBED = "chunk_transcribed"
EVENT_COACHING_ALERT = "coaching_alert"
EVENT_SUMMARY_UPDATED = "summary_updated"
EVENT_SESSION_STARTED = "session_started"
EVENT_SESSION_STOPPED = "session_stopped"
EVENT_PACE_WARNING = "pace_warning"
EVENT_COMPETITOR_MENTION = "competitor_mention"


@dataclass
class Event:
    """Represents an event in the system."""

    type: str
    data: dict[str, Any]
    session_id: str
    timestamp: datetime = field(default_factory=datetime.now)

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for JSON serialization."""
        return {
            "type": self.type,
            "data": self.data,
            "session_id": self.session_id,
            "timestamp": self.timestamp.isoformat(),
        }


AsyncHandler = Callable[[Event], Coroutine[Any, Any, None]]
SyncHandler = Callable[[Event], None]


class EventBus:
    """Simple pub/sub event bus supporting both sync and async handlers."""

    def __init__(self) -> None:
        self._async_subscribers: dict[str, list[asyncio.Queue[Event]]] = {}
        self._sync_handlers: dict[str, list[SyncHandler]] = {}

    def subscribe(self, event_type: str) -> asyncio.Queue[Event]:
        """
        Subscribe to events of a given type.

        Returns an asyncio.Queue that will receive events.
        Use this for async consumers (like WebSocket handlers).
        """
        if event_type not in self._async_subscribers:
            self._async_subscribers[event_type] = []

        queue: asyncio.Queue[Event] = asyncio.Queue()
        self._async_subscribers[event_type].append(queue)
        return queue

    def subscribe_all(self) -> asyncio.Queue[Event]:
        """
        Subscribe to all event types.

        Returns a queue that receives all events regardless of type.
        """
        return self.subscribe("*")

    def unsubscribe(self, event_type: str, queue: asyncio.Queue[Event]) -> None:
        """Unsubscribe a queue from events of a given type."""
        if event_type in self._async_subscribers:
            try:
                self._async_subscribers[event_type].remove(queue)
            except ValueError:
                pass

    def on(self, event_type: str, handler: SyncHandler) -> None:
        """
        Register a synchronous handler for an event type.

        Use this for simple callbacks that don't need async.
        """
        if event_type not in self._sync_handlers:
            self._sync_handlers[event_type] = []
        self._sync_handlers[event_type].append(handler)

    def off(self, event_type: str, handler: SyncHandler) -> None:
        """Unregister a synchronous handler."""
        if event_type in self._sync_handlers:
            try:
                self._sync_handlers[event_type].remove(handler)
            except ValueError:
                pass

    async def publish(self, event: Event) -> None:
        """
        Publish an event to all subscribers.

        Delivers to both async queues and sync handlers.
        """
        # Deliver to type-specific async subscribers
        if event.type in self._async_subscribers:
            for queue in self._async_subscribers[event.type]:
                await queue.put(event)

        # Deliver to wildcard subscribers
        if "*" in self._async_subscribers:
            for queue in self._async_subscribers["*"]:
                await queue.put(event)

        # Call sync handlers
        if event.type in self._sync_handlers:
            for handler in self._sync_handlers[event.type]:
                handler(event)

        if "*" in self._sync_handlers:
            for handler in self._sync_handlers["*"]:
                handler(event)

    def publish_sync(self, event: Event) -> None:
        """
        Synchronous publish for use in non-async contexts.

        Only delivers to sync handlers. For async subscribers,
        use publish() in an async context.
        """
        if event.type in self._sync_handlers:
            for handler in self._sync_handlers[event.type]:
                handler(event)

        if "*" in self._sync_handlers:
            for handler in self._sync_handlers["*"]:
                handler(event)


# Global event bus instance
_event_bus: EventBus | None = None


def get_event_bus() -> EventBus:
    """Get or create the global event bus instance."""
    global _event_bus
    if _event_bus is None:
        _event_bus = EventBus()
    return _event_bus


def reset_event_bus() -> None:
    """Reset the global event bus (useful for testing)."""
    global _event_bus
    _event_bus = None
