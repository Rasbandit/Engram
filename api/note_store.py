"""PostgreSQL note store — CRUD for canonical note content."""

import logging
import re
from datetime import datetime, timezone

import psycopg

from pool import get_pool

# Characters illegal on iOS/Android/Windows filesystems
_ILLEGAL_FILENAME_CHARS = re.compile(r'[\\:*?<>"|\x00]')

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
                    version INTEGER NOT NULL DEFAULT 1,
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


_MAX_SEGMENT_BYTES = 255


def sanitize_path(path: str) -> str:
    """Strip characters from filenames that are illegal on mobile/Windows.

    Also prevents path traversal (../), absolute paths, empty segments,
    and truncates segments exceeding filesystem limits (255 bytes).
    Folder separators (/) are preserved.
    """
    # Strip leading slashes to prevent absolute paths
    path = path.lstrip("/")

    parts = path.split("/")
    cleaned = []
    for part in parts:
        part = _ILLEGAL_FILENAME_CHARS.sub("", part)
        part = re.sub(r"  +", " ", part).strip()
        # Strip traversal segments (.. and variants like ". .")
        if part.replace(" ", "") in (".", "..") or ".." in part:
            continue
        # Skip empty segments (from double slashes)
        if not part:
            continue
        # Truncate segments exceeding filesystem limits
        if len(part.encode("utf-8")) > _MAX_SEGMENT_BYTES:
            encoded = part.encode("utf-8")[:_MAX_SEGMENT_BYTES]
            part = encoded.decode("utf-8", errors="ignore")
        cleaned.append(part)
    return "/".join(cleaned)


def _extract_folder(path: str) -> str:
    """Extract folder from path (everything before the last /)."""
    if "/" in path:
        return path.rsplit("/", 1)[0]
    return ""


def upsert_note(
    user_id: str, path: str, content: str, mtime: float,
    expected_version: int | None = None,
) -> dict:
    """Upsert a note into PostgreSQL. Returns the note dict.

    Path is sanitized to remove characters illegal on mobile/Windows filesystems.
    The returned dict contains the sanitized path.

    If expected_version is provided, the update only succeeds when the current
    server version matches (optimistic concurrency control). On mismatch,
    returns {"conflict": True, "server_note": {...}} instead of the upserted note.
    When expected_version is None, the update is unconditional (backwards compat).
    """
    path = sanitize_path(path)
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
                deleted_at = NULL,
                version = notes.version + 1
            WHERE (%s IS NULL OR notes.version = %s)
            RETURNING id, user_id, path, title, folder, tags, mtime, created_at, updated_at, version
        """, (user_id, path, title, content, folder, tags, mtime, now,
              expected_version, expected_version)).fetchone()

        if row is None:
            # Version mismatch — re-fetch current server state for the client
            server = conn.execute("""
                SELECT id, path, title, content, folder, tags, mtime, created_at, updated_at, version
                FROM notes WHERE user_id = %s AND path = %s AND deleted_at IS NULL
            """, (user_id, path)).fetchone()
            conn.commit()
            return {
                "conflict": True,
                "server_note": {
                    "id": server[0], "path": server[1], "title": server[2],
                    "content": server[3], "folder": server[4], "tags": server[5],
                    "mtime": server[6], "created_at": server[7].isoformat(),
                    "updated_at": server[8].isoformat(), "version": server[9],
                },
            }

        conn.commit()

    return {
        "id": row[0], "user_id": row[1], "path": row[2], "title": row[3],
        "folder": row[4], "tags": row[5], "mtime": row[6],
        "created_at": row[7].isoformat(), "updated_at": row[8].isoformat(),
        "version": row[9],
    }


def get_note(user_id: str, path: str) -> dict | None:
    """Get full note content from PostgreSQL."""
    pool = get_pool()
    with pool.connection() as conn:
        row = conn.execute("""
            SELECT id, path, title, content, folder, tags, mtime, created_at, updated_at, version
            FROM notes WHERE user_id = %s AND path = %s AND deleted_at IS NULL
        """, (user_id, path)).fetchone()

    if row is None:
        return None

    return {
        "id": row[0], "path": row[1], "title": row[2], "content": row[3],
        "folder": row[4], "tags": row[5], "mtime": row[6],
        "created_at": row[7].isoformat(), "updated_at": row[8].isoformat(),
        "version": row[9],
    }


def get_changes_since(user_id: str, since: datetime) -> list[dict]:
    """Get notes changed since a given timestamp (for sync)."""
    pool = get_pool()
    with pool.connection() as conn:
        rows = conn.execute("""
            SELECT path, title, content, folder, tags, mtime, updated_at, deleted_at, version
            FROM notes WHERE user_id = %s AND updated_at > %s
            ORDER BY updated_at ASC
        """, (user_id, since)).fetchall()

    return [
        {
            "path": r[0], "title": r[1], "content": r[2], "folder": r[3],
            "tags": r[4], "mtime": r[5], "updated_at": r[6].isoformat(),
            "deleted": r[7] is not None, "version": r[8],
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


def rename_note(user_id: str, old_path: str, new_path: str) -> dict | None:
    """Rename/move a note by updating its path. Returns updated note or None if not found."""
    new_folder = _extract_folder(new_path)
    now = datetime.now(timezone.utc)
    pool = get_pool()
    with pool.connection() as conn:
        row = conn.execute("""
            UPDATE notes SET path = %s, folder = %s, updated_at = %s
            WHERE user_id = %s AND path = %s AND deleted_at IS NULL
            RETURNING id, path, title, folder, tags, mtime, created_at, updated_at, version
        """, (new_path, new_folder, now, user_id, old_path)).fetchone()
        conn.commit()

    if row is None:
        return None

    return {
        "id": row[0], "path": row[1], "title": row[2], "folder": row[3],
        "tags": row[4], "mtime": row[5],
        "created_at": row[6].isoformat(), "updated_at": row[7].isoformat(),
        "version": row[8],
    }


def rename_folder(user_id: str, old_folder: str, new_folder: str) -> int:
    """Rename a folder by updating paths of all notes in it (and subfolders).
    Returns the number of notes updated."""
    now = datetime.now(timezone.utc)
    old_prefix = old_folder + "/"
    new_prefix = new_folder + "/"
    pool = get_pool()
    with pool.connection() as conn:
        # Exact folder match
        cursor = conn.execute("""
            UPDATE notes SET
                path = %s || substr(path, length(%s) + 1),
                folder = %s,
                updated_at = %s
            WHERE user_id = %s AND folder = %s AND deleted_at IS NULL
        """, (new_prefix, old_prefix, new_folder, now, user_id, old_folder))
        count = cursor.rowcount

        # Subfolder match (e.g. "A/B/C" when renaming "A" to "X")
        cursor = conn.execute("""
            UPDATE notes SET
                path = %s || substr(path, length(%s) + 1),
                folder = %s || substr(folder, length(%s) + 1),
                updated_at = %s
            WHERE user_id = %s AND folder LIKE %s AND deleted_at IS NULL
        """, (new_prefix, old_prefix, new_prefix, old_prefix, now, user_id, old_prefix + "%"))
        count += cursor.rowcount

        conn.commit()
    return count


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


def get_notes_in_folder(user_id: str, folder: str) -> list[dict]:
    """Get all notes in a specific folder (non-recursive)."""
    pool = get_pool()
    with pool.connection() as conn:
        rows = conn.execute("""
            SELECT path, title, tags, mtime, updated_at
            FROM notes WHERE user_id = %s AND folder = %s AND deleted_at IS NULL
            ORDER BY title
        """, (user_id, folder)).fetchall()

    return [
        {"path": r[0], "title": r[1], "tags": r[2], "mtime": r[3],
         "updated_at": r[4].isoformat()}
        for r in rows
    ]


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


def get_manifest(user_id: str) -> list[dict]:
    """Get path + content hash for all active notes. Hash computed in PostgreSQL."""
    pool = get_pool()
    with pool.connection() as conn:
        rows = conn.execute("""
            SELECT path, md5(content) AS content_hash, version
            FROM notes WHERE user_id = %s AND deleted_at IS NULL
            ORDER BY path
        """, (user_id,)).fetchall()

    return [{"path": r[0], "content_hash": r[1], "version": r[2]} for r in rows]


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
