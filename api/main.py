"""brain-api: FastAPI search service for Brain."""

import logging
import os
from contextlib import asynccontextmanager
from datetime import datetime, timezone

from fastapi import Depends, FastAPI, HTTPException, Query
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

import db
import note_store
from auth import get_current_user_api_key
from search import search
from notes import get_all_tags, get_note_by_path
from indexing import index_note, delete_note_index
from mcp_tools import mcp as mcp_server, MCPAuthMiddleware
from routes.web import router as web_router

logging.basicConfig(
    level=getattr(logging, os.environ.get("LOG_LEVEL", "INFO")),
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)

_mcp_app = mcp_server.http_app(path="/", transport="streamable-http")
mcp_app = MCPAuthMiddleware(_mcp_app)


@asynccontextmanager
async def lifespan(app: FastAPI):
    db.init_db()
    note_store.init_note_db()
    async with _mcp_app.lifespan(app):
        yield


app = FastAPI(title="Brain API", version="0.3.0", lifespan=lifespan)
app.mount("/mcp", mcp_app)
app.mount("/static", StaticFiles(directory="static"), name="static")
app.include_router(web_router)


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


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/search", response_model=SearchResponse)
def search_endpoint(req: SearchRequest, user: dict = Depends(get_current_user_api_key)):
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
def upsert_note_endpoint(req: NoteUpsertRequest, user: dict = Depends(get_current_user_api_key)):
    """Upsert a note to PostgreSQL and trigger indexing."""
    user_id = str(user["id"])
    note = note_store.upsert_note(user_id, req.path, req.content, req.mtime)
    try:
        chunk_count = index_note(req.path, req.content, req.mtime, user_id)
    except Exception as e:
        logging.getLogger("brain-api").warning("Indexing failed for %s: %s", req.path, e)
        chunk_count = 0
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
    deleted = note_store.delete_note(user_id, path)
    if not deleted:
        raise HTTPException(status_code=404, detail="Note not found")
    try:
        delete_note_index(path, user_id)
    except Exception as e:
        logging.getLogger("brain-api").warning("Failed to delete index for %s: %s", path, e)
    return {"deleted": True, "path": path}
