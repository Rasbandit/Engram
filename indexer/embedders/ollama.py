"""Embedder adapter for Ollama REST API."""

import logging
import os

import httpx

logger = logging.getLogger(__name__)

OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434")
EMBED_MODEL = os.environ.get("EMBED_MODEL", "nomic-embed-text")

_client = httpx.Client(timeout=120.0)


def embed_texts(texts: list[str]) -> list[list[float]]:
    """Embed a batch of texts via Ollama API. Returns list of embedding vectors."""
    resp = _client.post(
        f"{OLLAMA_URL}/api/embed",
        json={"model": EMBED_MODEL, "input": texts},
    )
    resp.raise_for_status()
    data = resp.json()
    return data["embeddings"]


def embed_single(text: str) -> list[float]:
    """Embed a single text."""
    return embed_texts([text])[0]
