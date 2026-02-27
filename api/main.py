"""brain-api: FastAPI search service for EDI-Brain."""

import logging
import os

from fastapi import FastAPI, Query
from pydantic import BaseModel, Field

from search import search
from notes import get_all_tags, get_note_by_path
from mcp_tools import mcp as mcp_server

logging.basicConfig(
    level=getattr(logging, os.environ.get("LOG_LEVEL", "INFO")),
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)

mcp_app = mcp_server.http_app(path="/", transport="sse")
app = FastAPI(title="EDI-Brain API", version="0.1.0", lifespan=mcp_app.lifespan)
app.mount("/mcp", mcp_app)


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


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/search", response_model=SearchResponse)
def search_endpoint(req: SearchRequest):
    results = search(req.query, limit=req.limit, tags=req.tags)
    return SearchResponse(query=req.query, results=results)


@app.get("/tags")
def tags_endpoint():
    return {"tags": get_all_tags()}


@app.get("/note")
def note_endpoint(source_path: str = Query(...)):
    result = get_note_by_path(source_path)
    if result is None:
        return {"error": "Note not found", "source_path": source_path}
    return result
