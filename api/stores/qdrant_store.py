"""Qdrant vector store adapter."""

import logging
import uuid

from qdrant_client import QdrantClient
from qdrant_client.models import (
    Distance,
    FieldCondition,
    Filter,
    MatchValue,
    PayloadSchemaType,
    PointStruct,
    VectorParams,
)

from config import EMBED_DIMS, QDRANT_URL

logger = logging.getLogger(__name__)


_client: QdrantClient | None = None


def get_client() -> QdrantClient:
    global _client
    if _client is None:
        _client = QdrantClient(url=QDRANT_URL)
    return _client


def ensure_collection(client: QdrantClient, name: str) -> None:
    """Create collection if it doesn't exist."""
    collections = [c.name for c in client.get_collections().collections]
    if name not in collections:
        client.create_collection(
            collection_name=name,
            vectors_config=VectorParams(size=EMBED_DIMS, distance=Distance.COSINE),
        )
        logger.info("Created collection: %s", name)

    # Ensure payload indexes
    for field_name in ("user_id", "source_path"):
        try:
            client.create_payload_index(
                collection_name=name,
                field_name=field_name,
                field_schema=PayloadSchemaType.KEYWORD,
            )
        except Exception:
            pass


def delete_by_source(client: QdrantClient, collection: str, source_path: str, user_id: str | None = None) -> None:
    """Delete all points for a given source file path, scoped to user_id if provided."""
    must_conditions = [FieldCondition(key="source_path", match=MatchValue(value=source_path))]
    if user_id:
        must_conditions.append(FieldCondition(key="user_id", match=MatchValue(value=user_id)))
    client.delete(
        collection_name=collection,
        points_selector=Filter(must=must_conditions),
    )


def upsert_chunks(
    client: QdrantClient,
    collection: str,
    texts: list[str],
    embeddings: list[list[float]],
    metadatas: list[dict],
) -> None:
    """Insert chunk vectors with metadata into Qdrant."""
    points = []
    for text, embedding, meta in zip(texts, embeddings, metadatas):
        point_id = str(uuid.uuid4())
        payload = {**meta, "text": text}
        points.append(PointStruct(id=point_id, vector=embedding, payload=payload))

    if points:
        client.upsert(collection_name=collection, points=points)
        logger.info("Upserted %d chunks to %s", len(points), collection)
