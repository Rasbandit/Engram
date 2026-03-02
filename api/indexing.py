"""Indexing orchestrator: parse → embed → upsert pipeline."""

import logging

from config import COLLECTION
from embedders import get_batch_embedder
from parsers.markdown import parse_markdown_content
from stores.qdrant_store import delete_by_source, ensure_collection, get_client, upsert_chunks

logger = logging.getLogger("brain-api")

_embed_batch = get_batch_embedder()


def index_note(path: str, content: str, mtime: float, user_id: str) -> int:
    """Parse, embed, and index a note. Returns chunk count."""
    chunks = parse_markdown_content(content, path, mtime, user_id, collection=COLLECTION)
    if not chunks:
        return 0

    client = get_client()
    ensure_collection(client, COLLECTION)

    # Remove old chunks for this note
    delete_by_source(client, COLLECTION, path, user_id=user_id)

    # Embed and upsert
    texts = [c.text for c in chunks]
    embeddings = _embed_batch(texts)
    metadatas = [c.metadata for c in chunks]
    upsert_chunks(client, COLLECTION, texts, embeddings, metadatas)

    logger.info("Indexed %d chunks for: %s", len(chunks), path)
    return len(chunks)


def delete_note_index(path: str, user_id: str):
    """Remove all chunks for a note from Qdrant."""
    client = get_client()
    delete_by_source(client, COLLECTION, path, user_id=user_id)
    logger.info("Deleted index for: %s", path)
