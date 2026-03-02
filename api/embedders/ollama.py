"""Ollama embedding adapter for brain-api."""

import httpx

from config import OLLAMA_URL, EMBED_MODEL

_client = httpx.Client(timeout=120.0)

BATCH_SIZE = 32


def embed(text: str) -> list[float]:
    """Embed a single text via Ollama API."""
    resp = _client.post(
        f"{OLLAMA_URL}/api/embed",
        json={"model": EMBED_MODEL, "input": [text]},
    )
    resp.raise_for_status()
    return resp.json()["embeddings"][0]


def embed_batch(texts: list[str]) -> list[list[float]]:
    """Embed multiple texts via Ollama API, batching internally."""
    all_embeddings: list[list[float]] = []
    for i in range(0, len(texts), BATCH_SIZE):
        batch = texts[i : i + BATCH_SIZE]
        resp = _client.post(
            f"{OLLAMA_URL}/api/embed",
            json={"model": EMBED_MODEL, "input": batch},
        )
        resp.raise_for_status()
        all_embeddings.extend(resp.json()["embeddings"])
    return all_embeddings
