"""OpenAI embedding adapter for brain-api."""

import os

import httpx

OPENAI_API_KEY = os.environ.get("OPENAI_API_KEY", "")
OPENAI_EMBED_MODEL = os.environ.get("OPENAI_EMBED_MODEL", "text-embedding-3-small")

_client = httpx.Client(timeout=120.0)

BATCH_SIZE = 100


def embed(text: str) -> list[float]:
    """Embed a single text via OpenAI API."""
    resp = _client.post(
        "https://api.openai.com/v1/embeddings",
        headers={"Authorization": f"Bearer {OPENAI_API_KEY}"},
        json={"model": OPENAI_EMBED_MODEL, "input": text},
    )
    resp.raise_for_status()
    return resp.json()["data"][0]["embedding"]


def embed_batch(texts: list[str]) -> list[list[float]]:
    """Embed multiple texts via OpenAI API, batching internally."""
    all_embeddings: list[list[float]] = []
    for i in range(0, len(texts), BATCH_SIZE):
        batch = texts[i : i + BATCH_SIZE]
        resp = _client.post(
            "https://api.openai.com/v1/embeddings",
            headers={"Authorization": f"Bearer {OPENAI_API_KEY}"},
            json={"model": OPENAI_EMBED_MODEL, "input": batch},
        )
        resp.raise_for_status()
        # OpenAI returns data sorted by index
        data = sorted(resp.json()["data"], key=lambda x: x["index"])
        all_embeddings.extend([d["embedding"] for d in data])
    return all_embeddings
