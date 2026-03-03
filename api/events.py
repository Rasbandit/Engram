"""Cross-process event bus using PostgreSQL LISTEN/NOTIFY.

Publishes note change events via NOTIFY so all workers receive them.
Each worker runs a listener that fans out to local asyncio.Queue subscribers.
"""

import asyncio
import json
import logging
import time
from dataclasses import dataclass, field
from enum import Enum

import psycopg

from config import DATABASE_URL

logger = logging.getLogger("engram-events")

CHANNEL = "note_events"


class EventType(str, Enum):
    upsert = "upsert"
    delete = "delete"


@dataclass
class NoteEvent:
    event_type: EventType
    user_id: str
    path: str
    timestamp: float = field(default_factory=time.time)
    kind: str = "note"

    def to_json(self) -> str:
        return json.dumps({
            "event_type": self.event_type.value,
            "user_id": self.user_id,
            "path": self.path,
            "timestamp": self.timestamp,
            "kind": self.kind,
        })

    @classmethod
    def from_json(cls, data: str) -> "NoteEvent":
        d = json.loads(data)
        return cls(
            event_type=EventType(d["event_type"]),
            user_id=d["user_id"],
            path=d["path"],
            timestamp=d.get("timestamp", time.time()),
            kind=d.get("kind", "note"),
        )


class EventBus:
    """Cross-process event bus using PostgreSQL LISTEN/NOTIFY with local fan-out."""

    def __init__(self) -> None:
        self._subscribers: dict[str, set[asyncio.Queue[NoteEvent]]] = {}
        self._listener_task: asyncio.Task | None = None
        self._running = False

    def publish(self, event: NoteEvent) -> None:
        """Publish event via PostgreSQL NOTIFY. Safe to call from sync code."""
        try:
            with psycopg.connect(DATABASE_URL, autocommit=True) as conn:
                conn.execute(
                    "SELECT pg_notify(%s, %s)",
                    (CHANNEL, event.to_json()),
                )
        except Exception:
            logger.warning("Failed to publish event via NOTIFY, falling back to local", exc_info=True)
            # Fall back to local delivery
            self._deliver_local(event)

    def _deliver_local(self, event: NoteEvent) -> None:
        """Deliver event to local subscribers only."""
        queues = self._subscribers.get(event.user_id, set())
        for q in list(queues):
            try:
                q.put_nowait(event)
            except asyncio.QueueFull:
                logger.warning("Dropping event for user %s — subscriber queue full", event.user_id)

    async def start_listener(self) -> None:
        """Start the background LISTEN task."""
        self._running = True
        self._listener_task = asyncio.create_task(self._listen_loop())
        logger.info("EventBus LISTEN started on channel %s", CHANNEL)

    async def stop_listener(self) -> None:
        """Stop the background LISTEN task."""
        self._running = False
        if self._listener_task is not None:
            self._listener_task.cancel()
            try:
                await self._listener_task
            except asyncio.CancelledError:
                pass
            self._listener_task = None
        logger.info("EventBus LISTEN stopped")

    async def _listen_loop(self) -> None:
        """Background loop: LISTEN on PostgreSQL and fan out to local subscribers."""
        while self._running:
            try:
                aconn = await psycopg.AsyncConnection.connect(
                    DATABASE_URL, autocommit=True
                )
                await aconn.execute(f"LISTEN {CHANNEL}")
                logger.info("EventBus connected to PostgreSQL LISTEN")
                async for notify in aconn.notifies():
                    if not self._running:
                        break
                    try:
                        event = NoteEvent.from_json(notify.payload)
                        self._deliver_local(event)
                    except Exception:
                        logger.warning("Failed to parse NOTIFY payload", exc_info=True)
                await aconn.close()
            except asyncio.CancelledError:
                break
            except Exception:
                logger.warning("EventBus listener disconnected, reconnecting in 2s", exc_info=True)
                await asyncio.sleep(2)

    async def subscribe(self, user_id: str):
        """Async generator yielding NoteEvents for a user.

        Cleans up on disconnect (generator close / cancellation).
        """
        q: asyncio.Queue[NoteEvent] = asyncio.Queue(maxsize=256)

        if user_id not in self._subscribers:
            self._subscribers[user_id] = set()
        self._subscribers[user_id].add(q)

        try:
            while True:
                event = await q.get()
                yield event
        finally:
            self._subscribers[user_id].discard(q)
            if not self._subscribers[user_id]:
                del self._subscribers[user_id]


# Module-level singleton
event_bus = EventBus()
