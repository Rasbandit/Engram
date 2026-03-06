"""OpenAI embedding adapter for engram-indexer."""

import os

import httpx

OPENAI_API_KEY = os.environ.get("OPENAI_API_KEY", "")
OPENAI_EMBED_MODEL = os.environ.get("OPENAI_EMBED_MODEL", "text-embedding-3-small")

_client = httpx.Client(timeout=120.0)


def embed_texts(texts: list[str]) -> list[list[float]]:
    """Embed a batch of texts via OpenAI API. Returns list of embedding vectors."""
    resp = _client.post(
        "https://api.openai.com/v1/embeddings",
        headers={"Authorization": f"Bearer {OPENAI_API_KEY}"},
        json={"model": OPENAI_EMBED_MODEL, "input": texts},
    )
    resp.raise_for_status()
    data = resp.json()
    # OpenAI returns embeddings sorted by index
    sorted_embeddings = sorted(data["data"], key=lambda x: x["index"])
    return [item["embedding"] for item in sorted_embeddings]


def embed_single(text: str) -> list[float]:
    """Embed a single text."""
    return embed_texts([text])[0]
