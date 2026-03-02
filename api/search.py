"""Two-stage search pipeline: Qdrant vector search → Jina reranker."""

import logging

import httpx
from qdrant_client import QdrantClient
from qdrant_client.models import FieldCondition, Filter, MatchAny, MatchValue

from config import COLLECTION, JINA_URL, QDRANT_URL
from embedders import get_embedder

logger = logging.getLogger("brain-api")

_http = httpx.Client(timeout=120.0)
_qdrant = QdrantClient(url=QDRANT_URL)
_embed = get_embedder()


def _rerank(query: str, texts: list[str]) -> list[float]:
    """Rerank texts and return scores aligned to input order.

    Uses index-based matching — Jina results include an index field
    corresponding to the input position.
    """
    resp = _http.post(
        f"{JINA_URL}/rerank",
        json={"query": query, "texts": texts, "top_n": len(texts)},
    )
    resp.raise_for_status()
    results = resp.json()

    scores = [0.0] * len(texts)
    for item in results:
        idx = item.get("index")
        if idx is not None and 0 <= idx < len(texts):
            scores[idx] = item["score"]
    return scores


def search(query: str, limit: int = 5, tags: list[str] | None = None, user_id: str | None = None) -> list[dict]:
    """Run two-stage search: vector retrieval → reranking."""
    vector = _embed(query)

    # Stage 1: Qdrant vector search — fetch more candidates than needed
    candidate_count = max(limit * 4, 20)

    must_conditions = []
    if user_id:
        must_conditions.append(FieldCondition(key="user_id", match=MatchValue(value=user_id)))
    if tags:
        must_conditions.append(FieldCondition(key="tags", match=MatchAny(any=tags)))
    query_filter = Filter(must=must_conditions) if must_conditions else None

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

        # Normalize reranker scores to 0-1 range to match vector score scale
        min_s = min(scores)
        max_s = max(scores)
        score_range = max_s - min_s
        if score_range > 0:
            norm_scores = [(s - min_s) / score_range for s in scores]
        else:
            norm_scores = [0.5] * len(scores)

        for c, raw_score, norm_score in zip(candidates, scores, norm_scores):
            c["rerank_score"] = raw_score
            # Blend: 40% vector similarity + 60% normalized reranker
            c["score"] = 0.4 * c["vector_score"] + 0.6 * norm_score
        candidates.sort(key=lambda x: x["score"], reverse=True)
    except Exception:
        logger.warning("Jina reranker failed, falling back to vector scores", exc_info=True)
        for c in candidates:
            c["score"] = c["vector_score"]

    return candidates[:limit]
