"""brain-api: FastAPI search service for EDI-Brain."""

import logging
import os

from fastapi import FastAPI
from pydantic import BaseModel, Field

from search import search

logging.basicConfig(
    level=getattr(logging, os.environ.get("LOG_LEVEL", "INFO")),
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)

app = FastAPI(title="EDI-Brain API", version="0.1.0")


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
