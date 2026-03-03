"""engram: FastAPI search service for Engram."""

import logging
import os
import time
from contextlib import asynccontextmanager
from datetime import datetime, timezone

from fastapi import Depends, FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field
from starlette.types import ASGIApp, Receive, Scope, Send

import base64

import db
import note_store
import attachment_store
from auth import get_current_user_api_key
from config import ASYNC_INDEXING, MAX_ATTACHMENT_SIZE, MAX_NOTE_SIZE, MAX_STORAGE_PER_USER, CORS_ORIGINS, QDRANT_URL, OLLAMA_URL
from pool import close_pool
from rate_limit import rate_limit
from search import search
from task_queue import TaskQueue
from notes import get_all_tags, get_note_by_path
from indexing import index_note, delete_note_index
from mcp_tools import mcp as mcp_server, MCPAuthMiddleware
from folder_index import ensure_folder_collection, rebuild_folder_index, search_folders
from routes.web import router as web_router
from routes.stream import router as stream_router
from events import event_bus, NoteEvent, EventType
import redis_client

logging.basicConfig(
    level=getattr(logging, os.environ.get("LOG_LEVEL", "INFO")),
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)

_mcp_app = mcp_server.http_app(path="/", transport="streamable-http")
mcp_app = MCPAuthMiddleware(_mcp_app)

_task_queue = TaskQueue()
_task_queue.register(index_note)


@asynccontextmanager
async def lifespan(app: FastAPI):
    db.init_db()
    note_store.init_note_db()
    attachment_store.init_attachment_db()
    ensure_folder_collection()
    await _task_queue.start()
    await event_bus.start_listener()
    async with _mcp_app.lifespan(app):
        yield
    await _task_queue.stop()
    await event_bus.stop_listener()
    await redis_client.close_redis()
    close_pool()


app = FastAPI(title="Engram", version="0.3.0", lifespan=lifespan)

_req_logger = logging.getLogger("engram.requests")


class RequestLoggingMiddleware:
    """Pure ASGI middleware for request logging — avoids BaseHTTPMiddleware body issues."""

    def __init__(self, app: ASGIApp):
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        start = time.monotonic()
        status_code = 0

        async def send_wrapper(message):
            nonlocal status_code
            if message["type"] == "http.response.start":
                status_code = message["status"]
            await send(message)

        await self.app(scope, receive, send_wrapper)
        duration = time.monotonic() - start
        method = scope.get("method", "?")
        path = scope.get("path", "?")
        _req_logger.info("%s %s %d %.3fs", method, path, status_code, duration)


app.add_middleware(RequestLoggingMiddleware)
app.add_middleware(
    CORSMiddleware,
    allow_origins=CORS_ORIGINS,
    allow_methods=["*"],
    allow_headers=["*"],
)
app.mount("/mcp", mcp_app)
app.mount("/static", StaticFiles(directory="static"), name="static")
app.include_router(web_router)
app.include_router(stream_router)


class SearchRequest(BaseModel):
    query: str
    limit: int = Field(default=5, ge=1, le=50)
    tags: list[str] | None = None


class SearchResult(BaseModel):
    text: str
    title: str | None = None
    heading_path: str | None = None
    source_path: str | None = None
    tags: list[str] = []
    wikilinks: list[str] = []
    score: float = 0.0
    vector_score: float = 0.0
    rerank_score: float = 0.0


class SearchResponse(BaseModel):
    query: str
    results: list[SearchResult]


class NoteUpsertRequest(BaseModel):
    path: str
    content: str
    mtime: float


class AttachmentUpsertRequest(BaseModel):
    path: str
    content_base64: str
    mime_type: str | None = None
    mtime: float


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/health/deep")
def health_deep():
    """Deep health check — verifies PostgreSQL, Qdrant, and Ollama connectivity."""
    import httpx
    from pool import get_pool

    checks = {}

    # PostgreSQL
    try:
        pool = get_pool()
        with pool.connection() as conn:
            conn.execute("SELECT 1")
        checks["postgresql"] = "ok"
    except Exception as e:
        checks["postgresql"] = f"error: {e}"

    # Qdrant
    try:
        resp = httpx.get(f"{QDRANT_URL}/healthz", timeout=5.0)
        checks["qdrant"] = "ok" if resp.status_code == 200 else f"status {resp.status_code}"
    except Exception as e:
        checks["qdrant"] = f"error: {e}"

    # Ollama
    try:
        resp = httpx.get(f"{OLLAMA_URL}/api/version", timeout=5.0)
        checks["ollama"] = "ok" if resp.status_code == 200 else f"status {resp.status_code}"
    except Exception as e:
        checks["ollama"] = f"error: {e}"

    # Redis (optional — only checked if configured)
    if redis_client.is_enabled():
        try:
            r = redis_client.get_sync()
            r.ping()
            checks["redis"] = "ok"
        except Exception as e:
            checks["redis"] = f"error: {e}"

    all_ok = all(v == "ok" for v in checks.values())
    status_code = 200 if all_ok else 503
    from starlette.responses import JSONResponse
    return JSONResponse({"status": "ok" if all_ok else "degraded", "checks": checks}, status_code=status_code)


@app.post("/search", response_model=SearchResponse)
def search_endpoint(req: SearchRequest, user: dict = Depends(rate_limit)):
    results = search(req.query, limit=req.limit, tags=req.tags, user_id=str(user["id"]))
    return SearchResponse(query=req.query, results=results)


@app.get("/tags")
def tags_endpoint(user: dict = Depends(get_current_user_api_key)):
    return {"tags": get_all_tags(user_id=str(user["id"]))}


@app.get("/note")
def note_endpoint(source_path: str = Query(...), user: dict = Depends(get_current_user_api_key)):
    result = get_note_by_path(source_path, user_id=str(user["id"]))
    if result is None:
        return {"error": "Note not found", "source_path": source_path}
    return result


# --- Ingest endpoints ---


@app.post("/notes")
def upsert_note_endpoint(req: NoteUpsertRequest, user: dict = Depends(rate_limit)):
    """Upsert a note to PostgreSQL and trigger indexing."""
    if len(req.content.encode("utf-8")) > MAX_NOTE_SIZE:
        raise HTTPException(status_code=413, detail=f"Note exceeds max size ({MAX_NOTE_SIZE} bytes)")
    user_id = str(user["id"])

    # Snapshot folder set before upsert to detect new folders
    folders_before = {f["folder"] for f in note_store.get_folders(user_id)}

    note = note_store.upsert_note(user_id, req.path, req.content, req.mtime)
    if ASYNC_INDEXING:
        _task_queue.enqueue(index_note, req.path, req.content, req.mtime, user_id)
        chunk_count = 0
    else:
        try:
            chunk_count = index_note(req.path, req.content, req.mtime, user_id)
        except Exception as e:
            logging.getLogger("engram").warning("Indexing failed for %s: %s", req.path, e)
            chunk_count = 0
    event_bus.publish(NoteEvent(EventType.upsert, user_id, req.path))

    # Rebuild folder index if folder set changed
    folders_after = {f["folder"] for f in note_store.get_folders(user_id)}
    if folders_after != folders_before:
        try:
            rebuild_folder_index(user_id)
        except Exception as e:
            logging.getLogger("engram").warning("Folder reindex failed: %s", e)

    return {"note": note, "chunks_indexed": chunk_count}


@app.get("/notes/changes")
def get_changes_endpoint(
    since: str = Query(..., description="ISO 8601 timestamp"),
    user: dict = Depends(get_current_user_api_key),
):
    """Get notes changed since a given timestamp (for plugin sync)."""
    user_id = str(user["id"])
    try:
        since_dt = datetime.fromisoformat(since.replace("Z", "+00:00"))
    except ValueError:
        raise HTTPException(status_code=400, detail="Invalid 'since' timestamp. Use ISO 8601 format.")
    changes = note_store.get_changes_since(user_id, since_dt)
    server_time = datetime.now(timezone.utc).isoformat()
    return {"changes": changes, "server_time": server_time}


@app.get("/folders")
def folders_endpoint(user: dict = Depends(get_current_user_api_key)):
    """Get folder tree with note counts."""
    user_id = str(user["id"])
    return {"folders": note_store.get_folders(user_id)}


class FolderSearchRequest(BaseModel):
    query: str
    limit: int = Field(default=5, ge=1, le=10)


@app.post("/folders/reindex")
def reindex_folders_endpoint(user: dict = Depends(get_current_user_api_key)):
    """Rebuild the folder vector index for semantic folder search."""
    user_id = str(user["id"])
    count = rebuild_folder_index(user_id)
    return {"folders_indexed": count}


@app.post("/folders/search")
def search_folders_endpoint(req: FolderSearchRequest, user: dict = Depends(get_current_user_api_key)):
    """Search for the best folder for a note based on content description."""
    user_id = str(user["id"])
    results = search_folders(req.query, user_id, limit=req.limit)
    return {"query": req.query, "results": results}


@app.get("/notes/{path:path}")
def get_note_endpoint(path: str, user: dict = Depends(get_current_user_api_key)):
    """Get full note from PostgreSQL."""
    user_id = str(user["id"])
    note = note_store.get_note(user_id, path)
    if note is None:
        raise HTTPException(status_code=404, detail="Note not found")
    return note


@app.delete("/notes/{path:path}")
def delete_note_endpoint(path: str, user: dict = Depends(get_current_user_api_key)):
    """Soft-delete a note from PostgreSQL and remove from Qdrant."""
    user_id = str(user["id"])

    # Snapshot folder set before delete
    folders_before = {f["folder"] for f in note_store.get_folders(user_id)}

    deleted = note_store.delete_note(user_id, path)
    if not deleted:
        raise HTTPException(status_code=404, detail="Note not found")
    try:
        delete_note_index(path, user_id)
    except Exception as e:
        logging.getLogger("engram").warning("Failed to delete index for %s: %s", path, e)
    event_bus.publish(NoteEvent(EventType.delete, user_id, path))

    # Rebuild folder index if folder set changed
    folders_after = {f["folder"] for f in note_store.get_folders(user_id)}
    if folders_after != folders_before:
        try:
            rebuild_folder_index(user_id)
        except Exception as e:
            logging.getLogger("engram").warning("Folder reindex failed: %s", e)

    return {"deleted": True, "path": path}


# --- Attachment endpoints ---


@app.post("/attachments")
def upsert_attachment_endpoint(req: AttachmentUpsertRequest, user: dict = Depends(rate_limit)):
    """Upsert a binary attachment (base64-encoded)."""
    user_id = str(user["id"])
    try:
        content = base64.b64decode(req.content_base64)
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid base64 content")

    if len(content) > MAX_ATTACHMENT_SIZE:
        raise HTTPException(status_code=413, detail=f"File exceeds max size ({MAX_ATTACHMENT_SIZE} bytes)")

    # Check user storage quota
    storage = attachment_store.get_user_storage(user_id)
    if storage["used_bytes"] + len(content) > MAX_STORAGE_PER_USER:
        raise HTTPException(status_code=413, detail="Storage quota exceeded")

    attachment = attachment_store.upsert_attachment(user_id, req.path, content, req.mtime, req.mime_type)
    event_bus.publish(NoteEvent(EventType.upsert, user_id, req.path, kind="attachment"))
    return {"attachment": attachment}


@app.get("/attachments/changes")
def get_attachment_changes_endpoint(
    since: str = Query(..., description="ISO 8601 timestamp"),
    user: dict = Depends(get_current_user_api_key),
):
    """Get attachment metadata changed since timestamp (no content)."""
    user_id = str(user["id"])
    try:
        since_dt = datetime.fromisoformat(since.replace("Z", "+00:00"))
    except ValueError:
        raise HTTPException(status_code=400, detail="Invalid 'since' timestamp. Use ISO 8601 format.")
    changes = attachment_store.get_changes_since(user_id, since_dt)
    server_time = datetime.now(timezone.utc).isoformat()
    return {"changes": changes, "server_time": server_time}


@app.get("/attachments/{path:path}")
def get_attachment_endpoint(path: str, user: dict = Depends(get_current_user_api_key)):
    """Get attachment content as base64."""
    user_id = str(user["id"])
    attachment = attachment_store.get_attachment(user_id, path)
    if attachment is None:
        raise HTTPException(status_code=404, detail="Attachment not found")
    content_bytes = attachment.pop("content")
    attachment["content_base64"] = base64.b64encode(content_bytes).decode("ascii")
    return attachment


@app.delete("/attachments/{path:path}")
def delete_attachment_endpoint(path: str, user: dict = Depends(get_current_user_api_key)):
    """Soft-delete an attachment."""
    user_id = str(user["id"])
    deleted = attachment_store.delete_attachment(user_id, path)
    if not deleted:
        raise HTTPException(status_code=404, detail="Attachment not found")
    event_bus.publish(NoteEvent(EventType.delete, user_id, path, kind="attachment"))
    return {"deleted": True, "path": path}


@app.get("/user/storage")
def user_storage_endpoint(user: dict = Depends(get_current_user_api_key)):
    """Get user's attachment storage usage."""
    user_id = str(user["id"])
    storage = attachment_store.get_user_storage(user_id)
    storage["max_bytes"] = MAX_STORAGE_PER_USER
    storage["max_attachment_bytes"] = MAX_ATTACHMENT_SIZE
    return storage
