"""Folder vector index — semantic search over vault folder structure."""

import logging
import uuid

from qdrant_client.models import (
    FieldCondition,
    Filter,
    MatchValue,
    PayloadSchemaType,
    PointStruct,
    VectorParams,
    Distance,
)

from config import EMBED_DIMS, FOLDER_COLLECTION
from embedders import get_embedder
from stores.qdrant_store import get_client
import note_store

logger = logging.getLogger("engram")


def ensure_folder_collection() -> None:
    """Create the folder collection if it doesn't exist."""
    client = get_client()
    collections = [c.name for c in client.get_collections().collections]
    if FOLDER_COLLECTION not in collections:
        client.create_collection(
            collection_name=FOLDER_COLLECTION,
            vectors_config=VectorParams(size=EMBED_DIMS, distance=Distance.COSINE),
        )
        logger.info("Created folder collection: %s", FOLDER_COLLECTION)

    for field_name in ("user_id", "folder"):
        try:
            client.create_payload_index(
                collection_name=FOLDER_COLLECTION,
                field_name=field_name,
                field_schema=PayloadSchemaType.KEYWORD,
            )
        except Exception:
            pass


def _build_folder_text(detail: dict) -> str:
    """Build enriched text for a folder to embed. Kept short for embedding context limits."""
    lines = [detail["folder"] or "(root)"]
    if detail["subfolders"]:
        lines.append(f"Subfolders: {', '.join(detail['subfolders'][:10])}")
    if detail["sample_titles"]:
        # Truncate individual titles to avoid context overflow from pathological data
        titles = [t[:80] for t in detail["sample_titles"]]
        lines.append(f"Notes: {', '.join(titles)}")
    return "\n".join(lines)


def rebuild_folder_index(user_id: str) -> int:
    """Rebuild the folder vector index for a user. Returns folder count."""
    ensure_folder_collection()
    client = get_client()

    details = note_store.get_folder_details(user_id)
    if not details:
        # Clear any existing points for this user
        client.delete(
            collection_name=FOLDER_COLLECTION,
            points_selector=Filter(must=[
                FieldCondition(key="user_id", match=MatchValue(value=user_id)),
            ]),
        )
        return 0

    # Build texts, filtering out any with empty content
    paired = [(d, _build_folder_text(d)) for d in details]
    paired = [(d, t) for d, t in paired if t.strip()]
    if not paired:
        # Clear any existing points for this user
        client.delete(
            collection_name=FOLDER_COLLECTION,
            points_selector=Filter(must=[
                FieldCondition(key="user_id", match=MatchValue(value=user_id)),
            ]),
        )
        return 0
    details, texts = zip(*paired)
    details = list(details)
    texts = list(texts)

    embed = get_embedder()
    embeddings = [embed(t) for t in texts]

    # Delete old points for this user
    client.delete(
        collection_name=FOLDER_COLLECTION,
        points_selector=Filter(must=[
            FieldCondition(key="user_id", match=MatchValue(value=user_id)),
        ]),
    )

    # Upsert new points
    points = []
    for detail, text, embedding in zip(details, texts, embeddings):
        points.append(PointStruct(
            id=str(uuid.uuid4()),
            vector=embedding,
            payload={
                "user_id": user_id,
                "folder": detail["folder"],
                "count": detail["count"],
                "text": text,
            },
        ))

    if points:
        client.upsert(collection_name=FOLDER_COLLECTION, points=points)

    logger.info("Rebuilt folder index for user %s: %d folders", user_id, len(points))
    return len(points)


def search_folders(query: str, user_id: str, limit: int = 5) -> list[dict]:
    """Search for folders semantically. Returns [{"folder": str, "score": float, "count": int}]."""
    ensure_folder_collection()
    client = get_client()

    embed = get_embedder()
    vector = embed(query)

    results = client.query_points(
        collection_name=FOLDER_COLLECTION,
        query=vector,
        limit=limit,
        with_payload=True,
        query_filter=Filter(must=[
            FieldCondition(key="user_id", match=MatchValue(value=user_id)),
        ]),
    )

    if not results.points:
        return []

    return [
        {
            "folder": point.payload.get("folder", ""),
            "score": point.score,
            "count": point.payload.get("count", 0),
        }
        for point in results.points
    ]
