"""PostgreSQL note store — CRUD for canonical note content."""

import logging
from datetime import datetime, timezone

import psycopg

from pool import get_pool

logger = logging.getLogger("engram")


def init_note_db():
    """Create notes table and indexes if they don't exist."""
    pool = get_pool()
    try:
        with pool.connection() as conn:
            conn.execute("""
                CREATE TABLE IF NOT EXISTS notes (
                    id SERIAL PRIMARY KEY,
                    user_id TEXT NOT NULL,
                    path TEXT NOT NULL,
                    title TEXT NOT NULL DEFAULT '',
                    content TEXT NOT NULL DEFAULT '',
                    folder TEXT NOT NULL DEFAULT '',
                    tags TEXT[] NOT NULL DEFAULT '{}',
                    mtime DOUBLE PRECISION NOT NULL DEFAULT 0,
                    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                    deleted_at TIMESTAMPTZ,
                    UNIQUE(user_id, path)
                )
            """)
            conn.execute("""
                CREATE INDEX IF NOT EXISTS idx_notes_user_folder
                ON notes(user_id, folder) WHERE deleted_at IS NULL
            """)
            conn.execute("""
                CREATE INDEX IF NOT EXISTS idx_notes_user_updated
                ON notes(user_id, updated_at) WHERE deleted_at IS NULL
            """)
            conn.execute("""
                CREATE INDEX IF NOT EXISTS idx_notes_user_tags
                ON notes USING GIN(tags) WHERE deleted_at IS NULL
            """)
            conn.commit()
    except psycopg.errors.UniqueViolation:
        # Concurrent workers may race on CREATE TABLE IF NOT EXISTS
        pass
    logger.info("PostgreSQL note store initialized")


def _extract_title(content: str, path: str) -> str:
    """Extract title from frontmatter or first heading, falling back to filename."""
    import frontmatter
    post = frontmatter.loads(content)
    fm_title = post.metadata.get("title") if post.metadata else None
    if fm_title:
        return fm_title

    # Try first heading
    for line in post.content.split("\n"):
        line = line.strip()
        if line.startswith("# "):
            return line[2:].strip()
        if line and not line.startswith("---"):
            break

    # Fall back to filename
    return path.rsplit("/", 1)[-1].removesuffix(".md")


def _extract_tags(content: str) -> list[str]:
    """Extract tags from frontmatter."""
    import frontmatter
    post = frontmatter.loads(content)
    tags = post.metadata.get("tags", []) if post.metadata else []
    if isinstance(tags, str):
        tags = [t.strip() for t in tags.split(",")]
    return tags


def _extract_folder(path: str) -> str:
    """Extract folder from path (everything before the last /)."""
    if "/" in path:
        return path.rsplit("/", 1)[0]
    return ""


def upsert_note(user_id: str, path: str, content: str, mtime: float) -> dict:
    """Upsert a note into PostgreSQL. Returns the note dict."""
    title = _extract_title(content, path)
    tags = _extract_tags(content)
    folder = _extract_folder(path)
    now = datetime.now(timezone.utc)

    pool = get_pool()
    with pool.connection() as conn:
        row = conn.execute("""
            INSERT INTO notes (user_id, path, title, content, folder, tags, mtime, updated_at, deleted_at)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, NULL)
            ON CONFLICT (user_id, path) DO UPDATE SET
                title = EXCLUDED.title,
                content = EXCLUDED.content,
                folder = EXCLUDED.folder,
                tags = EXCLUDED.tags,
                mtime = EXCLUDED.mtime,
                updated_at = EXCLUDED.updated_at,
                deleted_at = NULL
            RETURNING id, user_id, path, title, folder, tags, mtime, created_at, updated_at
        """, (user_id, path, title, content, folder, tags, mtime, now)).fetchone()
        conn.commit()

    return {
        "id": row[0], "user_id": row[1], "path": row[2], "title": row[3],
        "folder": row[4], "tags": row[5], "mtime": row[6],
        "created_at": row[7].isoformat(), "updated_at": row[8].isoformat(),
    }


def get_note(user_id: str, path: str) -> dict | None:
    """Get full note content from PostgreSQL."""
    pool = get_pool()
    with pool.connection() as conn:
        row = conn.execute("""
            SELECT id, path, title, content, folder, tags, mtime, created_at, updated_at
            FROM notes WHERE user_id = %s AND path = %s AND deleted_at IS NULL
        """, (user_id, path)).fetchone()

    if row is None:
        return None

    return {
        "id": row[0], "path": row[1], "title": row[2], "content": row[3],
        "folder": row[4], "tags": row[5], "mtime": row[6],
        "created_at": row[7].isoformat(), "updated_at": row[8].isoformat(),
    }


def get_changes_since(user_id: str, since: datetime) -> list[dict]:
    """Get notes changed since a given timestamp (for sync)."""
    pool = get_pool()
    with pool.connection() as conn:
        rows = conn.execute("""
            SELECT path, title, content, folder, tags, mtime, updated_at, deleted_at
            FROM notes WHERE user_id = %s AND updated_at > %s
            ORDER BY updated_at ASC
        """, (user_id, since)).fetchall()

    return [
        {
            "path": r[0], "title": r[1], "content": r[2], "folder": r[3],
            "tags": r[4], "mtime": r[5], "updated_at": r[6].isoformat(),
            "deleted": r[7] is not None,
        }
        for r in rows
    ]


def delete_note(user_id: str, path: str) -> bool:
    """Soft-delete a note. Returns True if a note was deleted."""
    now = datetime.now(timezone.utc)
    pool = get_pool()
    with pool.connection() as conn:
        cursor = conn.execute("""
            UPDATE notes SET deleted_at = %s, updated_at = %s
            WHERE user_id = %s AND path = %s AND deleted_at IS NULL
        """, (now, now, user_id, path))
        conn.commit()
    return cursor.rowcount > 0


def get_folders(user_id: str) -> list[dict]:
    """Get folder tree with note counts."""
    pool = get_pool()
    with pool.connection() as conn:
        rows = conn.execute("""
            SELECT folder, COUNT(*) as count
            FROM notes WHERE user_id = %s AND deleted_at IS NULL
            GROUP BY folder ORDER BY folder
        """, (user_id,)).fetchall()

    return [{"folder": r[0], "count": r[1]} for r in rows]


def get_folder_details(user_id: str) -> list[dict]:
    """Get folders with subfolders and sample note titles for embedding context.

    Returns: [{"folder": str, "count": int, "subfolders": list[str], "sample_titles": list[str]}]
    """
    pool = get_pool()
    with pool.connection() as conn:
        rows = conn.execute("""
            SELECT folder, title
            FROM notes WHERE user_id = %s AND deleted_at IS NULL
            ORDER BY folder, updated_at DESC
        """, (user_id,)).fetchall()

    # Group by folder
    from collections import defaultdict
    folder_map: dict[str, list[str]] = defaultdict(list)
    for folder, title in rows:
        folder_map[folder].append(title)

    # Build details with subfolder detection
    all_folders = set(folder_map.keys())
    results = []
    for folder, titles in folder_map.items():
        # Find direct subfolders
        prefix = f"{folder}/" if folder else ""
        subfolders = []
        for other in all_folders:
            if other == folder:
                continue
            if prefix and other.startswith(prefix):
                # Only direct children (no further / after prefix)
                remainder = other[len(prefix):]
                if "/" not in remainder:
                    subfolders.append(remainder)
            elif not prefix and "/" not in other and other:
                # Root's direct children are top-level folders
                subfolders.append(other.split("/")[0])

        # Deduplicate subfolders (root case can produce dupes)
        subfolders = sorted(set(subfolders))

        results.append({
            "folder": folder,
            "count": len(titles),
            "subfolders": subfolders,
            "sample_titles": titles[:5],  # Up to 5 most recent titles
        })

    return results


def get_all_tags_pg(user_id: str) -> list[dict]:
    """Get all unique tags with counts from PostgreSQL."""
    pool = get_pool()
    with pool.connection() as conn:
        rows = conn.execute("""
            SELECT tag, COUNT(*) as count
            FROM notes, unnest(tags) AS tag
            WHERE user_id = %s AND deleted_at IS NULL
            GROUP BY tag ORDER BY count DESC
        """, (user_id,)).fetchall()

    return [{"name": r[0], "count": r[1]} for r in rows]
