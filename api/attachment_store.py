"""PostgreSQL attachment store — CRUD for binary file content (images, PDFs, etc.)."""

import logging
import mimetypes
from datetime import datetime, timezone

import psycopg

from pool import get_pool

logger = logging.getLogger("brain-api")


def init_attachment_db():
    """Create attachments table and indexes if they don't exist."""
    pool = get_pool()
    with pool.connection() as conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS attachments (
                id SERIAL PRIMARY KEY,
                user_id TEXT NOT NULL,
                path TEXT NOT NULL,
                content BYTEA NOT NULL DEFAULT '',
                mime_type TEXT NOT NULL DEFAULT 'application/octet-stream',
                size_bytes BIGINT NOT NULL DEFAULT 0,
                mtime DOUBLE PRECISION NOT NULL DEFAULT 0,
                created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                deleted_at TIMESTAMPTZ,
                UNIQUE(user_id, path)
            )
        """)
        conn.execute("""
            CREATE INDEX IF NOT EXISTS idx_attachments_user_updated
            ON attachments(user_id, updated_at)
        """)
        conn.commit()
    logger.info("PostgreSQL attachment store initialized")


def _guess_mime_type(path: str) -> str:
    """Guess MIME type from file extension."""
    mime, _ = mimetypes.guess_type(path)
    return mime or "application/octet-stream"


def upsert_attachment(user_id: str, path: str, content: bytes, mtime: float, mime_type: str | None = None) -> dict:
    """Upsert an attachment into PostgreSQL. Returns metadata dict (no content)."""
    if mime_type is None:
        mime_type = _guess_mime_type(path)
    size_bytes = len(content)
    now = datetime.now(timezone.utc)

    pool = get_pool()
    with pool.connection() as conn:
        row = conn.execute("""
            INSERT INTO attachments (user_id, path, content, mime_type, size_bytes, mtime, updated_at, deleted_at)
            VALUES (%s, %s, %s, %s, %s, %s, %s, NULL)
            ON CONFLICT (user_id, path) DO UPDATE SET
                content = EXCLUDED.content,
                mime_type = EXCLUDED.mime_type,
                size_bytes = EXCLUDED.size_bytes,
                mtime = EXCLUDED.mtime,
                updated_at = EXCLUDED.updated_at,
                deleted_at = NULL
            RETURNING id, user_id, path, mime_type, size_bytes, mtime, created_at, updated_at
        """, (user_id, path, content, mime_type, size_bytes, mtime, now)).fetchone()
        conn.commit()

    return {
        "id": row[0], "user_id": row[1], "path": row[2],
        "mime_type": row[3], "size_bytes": row[4], "mtime": row[5],
        "created_at": row[6].isoformat(), "updated_at": row[7].isoformat(),
    }


def get_attachment(user_id: str, path: str) -> dict | None:
    """Get attachment with content from PostgreSQL."""
    pool = get_pool()
    with pool.connection() as conn:
        row = conn.execute("""
            SELECT id, path, content, mime_type, size_bytes, mtime, created_at, updated_at
            FROM attachments WHERE user_id = %s AND path = %s AND deleted_at IS NULL
        """, (user_id, path)).fetchone()

    if row is None:
        return None

    return {
        "id": row[0], "path": row[1], "content": bytes(row[2]),
        "mime_type": row[3], "size_bytes": row[4], "mtime": row[5],
        "created_at": row[6].isoformat(), "updated_at": row[7].isoformat(),
    }


def delete_attachment(user_id: str, path: str) -> bool:
    """Soft-delete an attachment. Returns True if deleted."""
    now = datetime.now(timezone.utc)
    pool = get_pool()
    with pool.connection() as conn:
        cursor = conn.execute("""
            UPDATE attachments SET deleted_at = %s, updated_at = %s
            WHERE user_id = %s AND path = %s AND deleted_at IS NULL
        """, (now, now, user_id, path))
        conn.commit()
    return cursor.rowcount > 0


def get_changes_since(user_id: str, since: datetime) -> list[dict]:
    """Get attachment metadata changed since timestamp (no content — for sync)."""
    pool = get_pool()
    with pool.connection() as conn:
        rows = conn.execute("""
            SELECT path, mime_type, size_bytes, mtime, updated_at, deleted_at
            FROM attachments WHERE user_id = %s AND updated_at > %s
            ORDER BY updated_at ASC
        """, (user_id, since)).fetchall()

    return [
        {
            "path": r[0], "mime_type": r[1], "size_bytes": r[2],
            "mtime": r[3], "updated_at": r[4].isoformat(),
            "deleted": r[5] is not None,
        }
        for r in rows
    ]


def get_user_storage(user_id: str) -> dict:
    """Get total storage used by a user's attachments."""
    pool = get_pool()
    with pool.connection() as conn:
        row = conn.execute("""
            SELECT COALESCE(SUM(size_bytes), 0), COUNT(*)
            FROM attachments WHERE user_id = %s AND deleted_at IS NULL
        """, (user_id,)).fetchone()

    return {
        "used_bytes": row[0],
        "file_count": row[1],
    }
