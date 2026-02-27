"""Two-stage search pipeline: Qdrant vector search → Jina reranker."""

import logging

import httpx
from qdrant_client import QdrantClient
from qdrant_client.models import FieldCondition, Filter, MatchAny

from config import COLLECTION, EMBED_MODEL, JINA_URL, OLLAMA_URL, QDRANT_URL

logger = logging.getLogger("brain-api")

_http = httpx.Client(timeout=120.0)
_qdrant = QdrantClient(url=QDRANT_URL)


def _embed(text: str) -> list[float]:
    resp = _http.post(
        f"{OLLAMA_URL}/api/embed",
        json={"model": EMBED_MODEL, "input": [text]},
    )
    resp.raise_for_status()
    return resp.json()["embeddings"][0]


def _rerank(query: str, texts: list[str]) -> list[float]:
    """Rerank texts and return scores in the same order as input texts."""
    resp = _http.post(
        f"{JINA_URL}/rerank",
        json={"query": query, "texts": texts},
    )
    resp.raise_for_status()
    # Jina may truncate/modify text, so match back by position using index
    # Request with index to get positional mapping
    results = resp.json()
    # Build text→score map from response, then match back to input by index
    # Since Jina returns texts in score-sorted order but may truncate them,
    # we need to send with index support or match differently.
    # Safest: send one-at-a-time is too slow. Instead, use the fact that
    # Jina returns results in the same count as inputs, sorted by score desc.
    # We can match by checking which input text starts with the returned text.
    scores = [0.0] * len(texts)
    for item in results:
        returned_text = item["text"]
        for i, original in enumerate(texts):
            if original.startswith(returned_text) or returned_text.startswith(original):
                scores[i] = item["score"]
                break
    return scores


def search(query: str, limit: int = 5, tags: list[str] | None = None) -> list[dict]:
    """Run two-stage search: vector retrieval → reranking."""
    vector = _embed(query)

    # Stage 1: Qdrant vector search — fetch more candidates than needed
    candidate_count = max(limit * 4, 20)

    query_filter = None
    if tags:
        query_filter = Filter(
            must=[FieldCondition(key="tags", match=MatchAny(any=tags))]
        )

    results = _qdrant.query_points(
        collection_name=COLLECTION,
        query=vector,
        limit=candidate_count,
        with_payload=True,
        query_filter=query_filter,
    )

    if not results.points:
        return []

    candidates = []
    for point in results.points:
        candidates.append({
            "text": point.payload.get("text", ""),
            "title": point.payload.get("title"),
            "heading_path": point.payload.get("heading_path"),
            "source_path": point.payload.get("source_path"),
            "tags": point.payload.get("tags", []),
            "wikilinks": point.payload.get("wikilinks", []),
            "vector_score": point.score,
        })

    # Stage 2: Jina reranker
    texts = [c["text"] for c in candidates]
    try:
        scores = _rerank(query, texts)
        for c, rerank_score in zip(candidates, scores):
            c["score"] = rerank_score
        candidates.sort(key=lambda x: x["score"], reverse=True)
    except Exception:
        logger.warning("Jina reranker failed, falling back to vector scores", exc_info=True)
        for c in candidates:
            c["score"] = c["vector_score"]

    return candidates[:limit]
