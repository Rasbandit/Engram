"""SSE endpoint for live note change notifications."""

import asyncio
import json
import logging

from fastapi import APIRouter, Depends, Request
from fastapi.responses import StreamingResponse

from auth import get_current_user_api_key
from events import event_bus

logger = logging.getLogger("brain-stream")

router = APIRouter()


@router.get("/notes/stream")
async def notes_stream(request: Request, user: dict = Depends(get_current_user_api_key)):
    """Server-Sent Events stream for note changes.

    Sends `event: connected` on open, then `event: note_change` with JSON
    data for each upsert/delete.
    """
    user_id = str(user["id"])

    async def event_generator():
        # Send initial connected event
        yield f"event: connected\ndata: {json.dumps({'user_id': user_id})}\n\n"

        async for event in event_bus.subscribe(user_id):
            if await request.is_disconnected():
                break

            data = json.dumps({
                "event_type": event.event_type.value,
                "path": event.path,
                "timestamp": event.timestamp,
                "kind": event.kind,
            })
            yield f"event: note_change\ndata: {data}\n\n"

    return StreamingResponse(
        event_generator(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
        },
    )
