"""Note retrieval and tag listing — PostgreSQL primary, Qdrant fallback."""

import logging

import note_store

logger = logging.getLogger("engram")


def get_all_tags(user_id: str | None = None) -> list[dict]:
    """Get all unique tags with document counts from PostgreSQL."""
    if not user_id:
        return []
    return note_store.get_all_tags_pg(user_id)


def get_note_by_path(source_path: str, user_id: str | None = None) -> dict | None:
    """Get full note content from PostgreSQL."""
    if not user_id:
        return None

    note = note_store.get_note(user_id, source_path)
    if note:
        return note

    # Try without /vault/ prefix or with it
    if source_path.startswith("/vault/"):
        alt_path = source_path[7:]  # strip /vault/
    else:
        alt_path = "/vault/" + source_path.lstrip("/")

    return note_store.get_note(user_id, alt_path)
