"""Qdrant vector store adapter."""

import logging
import os
import uuid

from qdrant_client import QdrantClient
from qdrant_client.models import (
    Distance,
    FieldCondition,
    Filter,
    MatchValue,
    PointStruct,
    VectorParams,
)

logger = logging.getLogger(__name__)

QDRANT_URL = os.environ.get("QDRANT_URL", "http://localhost:6333")
EMBED_DIMS = int(os.environ.get("EMBED_DIMS", "768"))


def get_client() -> QdrantClient:
    return QdrantClient(url=QDRANT_URL)


def ensure_collection(client: QdrantClient, name: str) -> None:
    """Create collection if it doesn't exist."""
    collections = [c.name for c in client.get_collections().collections]
    if name not in collections:
        client.create_collection(
            collection_name=name,
            vectors_config=VectorParams(size=EMBED_DIMS, distance=Distance.COSINE),
        )
        logger.info("Created collection: %s", name)
    else:
        logger.info("Collection already exists: %s", name)


def delete_by_source(client: QdrantClient, collection: str, source_path: str) -> None:
    """Delete all points for a given source file path."""
    client.delete(
        collection_name=collection,
        points_selector=Filter(
            must=[FieldCondition(key="source_path", match=MatchValue(value=source_path))]
        ),
    )
    logger.debug("Deleted existing chunks for: %s", source_path)


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
