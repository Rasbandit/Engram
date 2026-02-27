"""Note retrieval and tag listing via Qdrant."""

import logging
from collections import Counter

from qdrant_client import QdrantClient
from qdrant_client.models import FieldCondition, Filter, MatchValue

from config import COLLECTION, QDRANT_URL

logger = logging.getLogger("brain-api")

_qdrant = QdrantClient(url=QDRANT_URL)


def get_all_tags() -> list[dict]:
    """Get all unique tags with document counts by scrolling through Qdrant."""
    tag_counts: Counter = Counter()
    offset = None

    while True:
        results, offset = _qdrant.scroll(
            collection_name=COLLECTION,
            limit=100,
            offset=offset,
            with_payload=["tags"],
            with_vectors=False,
        )
        if not results:
            break
        for point in results:
            for tag in point.payload.get("tags", []):
                tag_counts[tag] += 1
        if offset is None:
            break

    return [{"name": tag, "count": count} for tag, count in tag_counts.most_common()]


def get_note_by_path(source_path: str) -> dict | None:
    """Get all chunks for a note, ordered by chunk_index."""
    results, _ = _qdrant.scroll(
        collection_name=COLLECTION,
        scroll_filter=Filter(
            must=[FieldCondition(key="source_path", match=MatchValue(value=source_path))]
        ),
        limit=200,
        with_payload=True,
        with_vectors=False,
    )

    if not results:
        return None

    # Sort by chunk_index
    chunks = sorted(results, key=lambda p: p.payload.get("chunk_index", 0))

    first = chunks[0].payload
    return {
        "title": first.get("title"),
        "source_path": source_path,
        "tags": first.get("tags", []),
        "chunks": [
            {
                "text": p.payload.get("text", ""),
                "heading_path": p.payload.get("heading_path"),
            }
            for p in chunks
        ],
    }
