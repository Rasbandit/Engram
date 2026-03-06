"""MCP tool definitions for Engram, with Bearer token auth via ASGI middleware."""

import contextvars
import logging
import threading
import time
from typing import Optional

from fastmcp import FastMCP
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Receive, Scope, Send

import db
import note_store
from search import search
from indexing import index_note, delete_note_index
from events import event_bus, NoteEvent, EventType
from folder_index import rebuild_folder_index, search_folders

logger = logging.getLogger("engram-mcp")

# Context variable to thread user_id into MCP tool functions
_current_user_id: contextvars.ContextVar[str | None] = contextvars.ContextVar(
    "_current_user_id", default=None
)


class MCPAuthMiddleware:
    """ASGI middleware that validates Bearer token and sets user_id in contextvars."""

    def __init__(self, app: ASGIApp):
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send):
        if scope["type"] not in ("http", "websocket"):
            await self.app(scope, receive, send)
            return

        # Extract Bearer token from headers
        headers = dict(scope.get("headers", []))
        auth_header = headers.get(b"authorization", b"").decode()

        if not auth_header.startswith("Bearer "):
            response = JSONResponse(
                {"detail": "Missing or invalid Authorization header"},
                status_code=401,
            )
            await response(scope, receive, send)
            return

        token = auth_header[7:]  # Strip "Bearer "
        user = db.validate_api_key(token)
        if user is None:
            response = JSONResponse({"detail": "Invalid API key"}, status_code=401)
            await response(scope, receive, send)
            return

        # Set user_id in contextvars for MCP tools to read
        token = _current_user_id.set(str(user["id"]))
        try:
            await self.app(scope, receive, send)
        finally:
            _current_user_id.reset(token)


mcp = FastMCP("Engram")


@mcp.tool()
def search_notes(query: str, limit: int = 5, tags: Optional[list[str]] = None) -> str:
    """Search your personal knowledge base. Finds relevant notes from your
    Obsidian vault using semantic search with neural reranking.

    Use when the user asks about their notes, vault, knowledge, or memory.
    Handles natural queries like "what do I know about X" or "find my notes on Y".

    Args:
        query: Natural language search query
        limit: Maximum number of results (1-20, default 5)
        tags: Optional list of tags to filter by (e.g. ["health", "supplements"])
    """
    user_id = _current_user_id.get()
    results = search(query, limit=min(limit, 20), tags=tags, user_id=user_id)

    lines = []
    for i, r in enumerate(results, 1):
        lines.append(f"## Result {i} (score: {r['score']:.3f})")
        if r.get("title"):
            lines.append(f"**Title:** {r['title']}")
        if r.get("heading_path"):
            lines.append(f"**Section:** {r['heading_path']}")
        if r.get("source_path"):
            lines.append(f"**Source:** {r['source_path']}")
        if r.get("tags"):
            lines.append(f"**Tags:** {', '.join(r['tags'])}")
        lines.append(f"\n{r['text']}\n")

    return "\n".join(lines) if lines else "No results found."


@mcp.tool()
def get_note(source_path: str) -> str:
    """Retrieve the full content of a specific note from the knowledge base.
    Use after searching to read a complete note, or when the user references
    a specific note by name or path.

    Args:
        source_path: The path of the note (e.g. "2. Knowledge Vault/Health/Omega Oils.md")
    """
    user_id = _current_user_id.get()

    # Try exact path first, then with/without /vault/ prefix
    note = note_store.get_note(user_id, source_path)
    if note is None and source_path.startswith("/vault/"):
        note = note_store.get_note(user_id, source_path[7:])
    if note is None and not source_path.startswith("/vault/"):
        note = note_store.get_note(user_id, "/vault/" + source_path.lstrip("/"))

    if note is None:
        return f"Note not found: {source_path}"

    lines = [f"# {note['title']}"]
    if note.get("tags"):
        lines.append(f"**Tags:** {', '.join(note['tags'])}")
    lines.append(f"**Path:** {note['path']}")
    lines.append(f"**Folder:** {note.get('folder', '')}\n")
    lines.append(note["content"])

    return "\n".join(lines)


@mcp.tool()
def list_tags() -> str:
    """List all tags in the personal knowledge base with document counts.
    Use to explore what topics exist in the vault or help the user find notes by category."""
    user_id = _current_user_id.get()
    tags = note_store.get_all_tags_pg(user_id)

    if not tags:
        return "No tags found."

    lines = ["| Tag | Count |", "|-----|-------|"]
    for t in tags:
        lines.append(f"| {t['name']} | {t['count']} |")

    return "\n".join(lines)


@mcp.tool()
def list_folders() -> str:
    """List all folders in the personal knowledge base with note counts.
    Use to understand the vault's organization or help place new notes."""
    user_id = _current_user_id.get()
    folders = note_store.get_folders(user_id)

    if not folders:
        return "No folders found."

    lines = ["| Folder | Notes |", "|--------|-------|"]
    for f in folders:
        folder_name = f["folder"] or "(root)"
        lines.append(f"| {folder_name} | {f['count']} |")

    return "\n".join(lines)


@mcp.tool()
def list_folder(folder: str) -> str:
    """List all notes in a specific folder. Use to browse the contents of a folder
    after calling list_folders, or to see what notes exist in a known location.

    Pass an empty string to list notes in the vault root.

    Args:
        folder: Folder path (e.g. "2. Knowledge Vault/Health") or "" for root
    """
    user_id = _current_user_id.get()
    notes = note_store.get_notes_in_folder(user_id, folder)

    if not notes:
        folder_label = folder or "(root)"
        return f"No notes found in folder: {folder_label}"

    lines = [f"**Folder:** {folder or '(root)'}", "",
             "| Title | Path | Tags |", "|-------|------|------|"]
    for n in notes:
        tags = ", ".join(n["tags"]) if n["tags"] else ""
        lines.append(f"| {n['title']} | {n['path']} | {tags} |")

    return "\n".join(lines)


@mcp.tool()
def suggest_folder(description: str, limit: int = 5) -> str:
    """Find the best existing folder for a new note based on a description of its content.
    Returns top matching folders ranked by semantic similarity.
    If the folder index hasn't been built yet, builds it automatically.

    Call this before create_note whenever the right folder is unclear. Always prefer
    an existing folder over inventing a new one — use the top result unless it's clearly wrong.

    Args:
        description: What the note is about (e.g. "blood test results for iron panel")
        limit: Number of suggestions (1-10, default 5)
    """
    user_id = _current_user_id.get()
    limit = max(1, min(limit, 10))

    results = search_folders(description, user_id, limit=limit)

    # Cold start: if no results, build the index and retry
    if not results:
        count = rebuild_folder_index(user_id)
        if count > 0:
            results = search_folders(description, user_id, limit=limit)

    if not results:
        return "No folders found. The vault may be empty."

    lines = ["| Rank | Folder | Score | Notes |", "|------|--------|-------|-------|"]
    for i, r in enumerate(results, 1):
        folder_name = r["folder"] or "(root)"
        lines.append(f"| {i} | {folder_name} | {r['score']:.3f} | {r['count']} |")

    return "\n".join(lines)


@mcp.tool()
def delete_note(path: str) -> str:
    """Delete a note from the knowledge base. Removes it from storage and search index.
    The deletion will sync to all connected Obsidian devices.

    Args:
        path: The path of the note to delete (e.g. "2. Knowledge Vault/Health/Old Note.md")
    """
    user_id = _current_user_id.get()

    # Snapshot folder set before delete
    folders_before = {f["folder"] for f in note_store.get_folders(user_id)}

    deleted = note_store.delete_note(user_id, path)
    if not deleted:
        return f"Note not found: {path}"

    try:
        delete_note_index(path, user_id)
    except Exception as e:
        logger.warning("Failed to delete index for %s: %s", path, e)

    event_bus.publish(NoteEvent(EventType.delete, user_id, path))

    # Rebuild folder index if folder set changed
    folders_after = {f["folder"] for f in note_store.get_folders(user_id)}
    if folders_after != folders_before:
        threading.Thread(
            target=_rebuild_folder_index_bg, args=(user_id,), daemon=True
        ).start()

    return f"Note deleted: {path}"


@mcp.tool()
def rename_note(old_path: str, new_path: str) -> str:
    """Rename or move a note to a new path. Updates storage and search index.
    The change will sync to all connected Obsidian devices.

    Args:
        old_path: Current path of the note (e.g. "2. Knowledge Vault/Health/Old Name.md")
        new_path: New path for the note (e.g. "2. Knowledge Vault/Health/New Name.md")
    """
    user_id = _current_user_id.get()

    # Get content before rename (needed for reindexing)
    existing = note_store.get_note(user_id, old_path)
    if existing is None:
        return f"Note not found: {old_path}"

    result = note_store.rename_note(user_id, old_path, new_path)
    if result is None:
        return f"Failed to rename note: {old_path}"

    # Remove old index, create new one
    try:
        delete_note_index(old_path, user_id)
        index_note(new_path, existing["content"], existing["mtime"], user_id)
    except Exception as e:
        logger.warning("Reindex after rename failed for %s: %s", new_path, e)

    event_bus.publish(NoteEvent(EventType.delete, user_id, old_path))
    event_bus.publish(NoteEvent(EventType.upsert, user_id, new_path))

    # Rebuild folder index if folder changed
    old_folder = old_path.rsplit("/", 1)[0] if "/" in old_path else ""
    new_folder = new_path.rsplit("/", 1)[0] if "/" in new_path else ""
    if old_folder != new_folder:
        threading.Thread(
            target=_rebuild_folder_index_bg, args=(user_id,), daemon=True
        ).start()

    return f"Note renamed: {old_path} → {new_path}"


@mcp.tool()
def rename_folder(old_folder: str, new_folder: str) -> str:
    """Rename a folder and all notes within it (including subfolders).
    All affected notes will be reindexed and synced to connected Obsidian devices.

    Args:
        old_folder: Current folder path (e.g. "2. Knowledge Vault/Old Name")
        new_folder: New folder path (e.g. "2. Knowledge Vault/New Name")
    """
    user_id = _current_user_id.get()

    # Get all notes that will be affected (for reindexing)
    notes_before = note_store.get_notes_in_folder(user_id, old_folder)
    # Also get subfolder notes
    all_folders = note_store.get_folders(user_id)
    old_prefix = old_folder + "/"
    subfolder_notes = []
    for f in all_folders:
        if f["folder"].startswith(old_prefix):
            subfolder_notes.extend(
                note_store.get_notes_in_folder(user_id, f["folder"])
            )

    all_affected = notes_before + subfolder_notes
    if not all_affected:
        return f"No notes found in folder: {old_folder}"

    # Collect old paths and content before rename
    old_notes = []
    for n in all_affected:
        full = note_store.get_note(user_id, n["path"])
        if full:
            old_notes.append({"path": full["path"], "content": full["content"], "mtime": full["mtime"]})

    count = note_store.rename_folder(user_id, old_folder, new_folder)

    # Reindex: remove old vectors, index new paths
    for n in old_notes:
        new_path = new_folder + n["path"][len(old_folder):]
        try:
            delete_note_index(n["path"], user_id)
            index_note(new_path, n["content"], n["mtime"], user_id)
        except Exception as e:
            logger.warning("Reindex failed for %s: %s", new_path, e)
        event_bus.publish(NoteEvent(EventType.delete, user_id, n["path"]))
        event_bus.publish(NoteEvent(EventType.upsert, user_id, new_path))

    threading.Thread(
        target=_rebuild_folder_index_bg, args=(user_id,), daemon=True
    ).start()

    return f"Folder renamed: {old_folder} → {new_folder} ({count} notes updated)"


@mcp.tool()
def write_note(path: str, content: str) -> str:
    """Write or update a note in the knowledge base. Saves to storage and
    indexes for search. The note will sync to all connected Obsidian devices.

    Args:
        path: Full path for the note (e.g. "2. Knowledge Vault/Health/New Note.md")
        content: Full markdown content of the note
    """
    user_id = _current_user_id.get()
    mtime = time.time()

    note = note_store.upsert_note(user_id, path, content, mtime)
    try:
        chunk_count = index_note(path, content, mtime, user_id)
    except Exception as e:
        logger.warning("Indexing failed for %s: %s", path, e)
        chunk_count = 0

    event_bus.publish(NoteEvent(EventType.upsert, user_id, path))
    return f"Note saved: {path} ({chunk_count} chunks indexed)"


@mcp.tool()
def append_to_note(path: str, text: str) -> str:
    """Append text to an existing note, or create it if it doesn't exist.
    The updated note will be re-indexed and synced to all connected Obsidian devices.

    Args:
        path: Full path for the note (e.g. "2. Knowledge Vault/Health/Supplements.md")
        text: Text to append to the end of the note
    """
    user_id = _current_user_id.get()
    mtime = time.time()

    existing = note_store.get_note(user_id, path)
    if existing:
        content = existing["content"].rstrip("\n") + "\n\n" + text
        action = "appended to"
    else:
        # Create new note with title from filename
        title = path.rsplit("/", 1)[-1].removesuffix(".md")
        content = f"# {title}\n\n{text}"
        action = "created"

    note_store.upsert_note(user_id, path, content, mtime)
    try:
        chunk_count = index_note(path, content, mtime, user_id)
    except Exception as e:
        logger.warning("Indexing failed for %s: %s", path, e)
        chunk_count = 0

    event_bus.publish(NoteEvent(EventType.upsert, user_id, path))
    return f"Note {action}: {path} ({chunk_count} chunks indexed)"


@mcp.tool()
def update_section(
    path: str, heading: str, content: str, level: int = 2
) -> str:
    """Replace the content under a specific heading in an existing note.
    Everything from the matched heading to the next heading of the same or higher
    level is replaced. The heading line itself is preserved.

    The updated note will be re-indexed and synced to all connected Obsidian devices.

    Args:
        path: Full path of the note (e.g. "2. Knowledge Vault/Health/Supplements.md")
        heading: The heading text to find (without the # prefix, e.g. "Shopping List")
        content: New content to place under the heading (replaces old content)
        level: Heading level (1-6, default 2 for ##)
    """
    user_id = _current_user_id.get()

    existing = note_store.get_note(user_id, path)
    if existing is None:
        return f"Note not found: {path}"

    prefix = "#" * max(1, min(level, 6)) + " "
    target = prefix + heading
    lines = existing["content"].split("\n")

    # Find the heading line
    start = None
    for i, line in enumerate(lines):
        if line.strip() == target.strip():
            start = i
            break

    if start is None:
        return f"Heading not found: {target}"

    # Find the end: next heading of same or higher level, or EOF
    end = len(lines)
    for i in range(start + 1, len(lines)):
        stripped = lines[i].lstrip()
        if stripped.startswith("#"):
            # Count the heading level
            h_level = 0
            for ch in stripped:
                if ch == "#":
                    h_level += 1
                else:
                    break
            if h_level <= level and stripped[h_level:h_level + 1] in (" ", ""):
                end = i
                break

    # Rebuild: heading line + new content + rest of file
    new_lines = lines[:start + 1] + [content.rstrip("\n")] + lines[end:]
    new_content = "\n".join(new_lines)

    mtime = time.time()
    note_store.upsert_note(user_id, path, new_content, mtime)
    try:
        chunk_count = index_note(path, new_content, mtime, user_id)
    except Exception as e:
        logger.warning("Indexing failed for %s: %s", path, e)
        chunk_count = 0

    event_bus.publish(NoteEvent(EventType.upsert, user_id, path))
    return f"Section '{heading}' updated in {path} ({chunk_count} chunks indexed)"


@mcp.tool()
def patch_note(path: str, find: str, replace: str, occurrence: int = 0) -> str:
    """Find and replace text in an existing note. By default replaces the first
    occurrence. Set occurrence to -1 to replace all occurrences.

    The updated note will be re-indexed and synced to all connected Obsidian devices.

    Args:
        path: Full path of the note (e.g. "2. Knowledge Vault/Health/Supplements.md")
        find: Exact text to find in the note
        replace: Text to replace it with
        occurrence: Which occurrence to replace (0 = first, 1 = second, -1 = all)
    """
    user_id = _current_user_id.get()

    existing = note_store.get_note(user_id, path)
    if existing is None:
        return f"Note not found: {path}"

    old_content = existing["content"]

    if find not in old_content:
        return f"Text not found in {path}"

    if occurrence == -1:
        new_content = old_content.replace(find, replace)
        count = old_content.count(find)
    else:
        # Replace the Nth occurrence (0-indexed)
        parts = old_content.split(find)
        if occurrence >= len(parts) - 1:
            return f"Occurrence {occurrence} not found (only {len(parts) - 1} matches in {path})"
        new_content = (
            find.join(parts[: occurrence + 1])
            + replace
            + find.join(parts[occurrence + 1 :])
        )
        count = 1

    mtime = time.time()
    note_store.upsert_note(user_id, path, new_content, mtime)
    try:
        chunk_count = index_note(path, new_content, mtime, user_id)
    except Exception as e:
        logger.warning("Indexing failed for %s: %s", path, e)
        chunk_count = 0

    event_bus.publish(NoteEvent(EventType.upsert, user_id, path))
    return f"Replaced {count} occurrence(s) in {path} ({chunk_count} chunks indexed)"


@mcp.tool()
def create_note(title: str, content: str, suggested_folder: Optional[str] = None) -> str:
    """Create a new note in the knowledge base with automatic folder placement.
    The note will be indexed for search and sync to all connected Obsidian devices.

    Folder placement: if `suggested_folder` is omitted, the note is placed automatically
    using semantic search over existing vault folders. This is the preferred behaviour —
    do NOT invent a folder name. Only pass `suggested_folder` if the user explicitly
    requested a specific folder. When unsure, call `suggest_folder` first to inspect
    the top matches, then omit `suggested_folder` and let auto-placement decide.

    Args:
        title: Title for the new note
        content: Markdown content of the note
        suggested_folder: Only set this when the user explicitly named a folder.
            Leave unset to auto-place into the most semantically relevant existing folder.
    """
    user_id = _current_user_id.get()

    if suggested_folder:
        folder = suggested_folder.rstrip("/")
    else:
        folder = _auto_place_folder(title, content, user_id)

    # Build full path
    filename = title.replace("/", "-") + ".md"
    path = f"{folder}/{filename}" if folder else filename

    # Add title as H1 if content doesn't start with one
    if not content.strip().startswith("# "):
        content = f"# {title}\n\n{content}"

    mtime = time.time()
    note_store.upsert_note(user_id, path, content, mtime)
    try:
        chunk_count = index_note(path, content, mtime, user_id)
    except Exception as e:
        logger.warning("Indexing failed for %s: %s", path, e)
        chunk_count = 0

    event_bus.publish(NoteEvent(EventType.upsert, user_id, path))

    # Rebuild folder index in background so future placements see the new note
    threading.Thread(
        target=_rebuild_folder_index_bg, args=(user_id,), daemon=True
    ).start()

    return f"Note created: {path} ({chunk_count} chunks indexed)"


def _rebuild_folder_index_bg(user_id: str) -> None:
    """Rebuild folder index silently in a background thread."""
    try:
        rebuild_folder_index(user_id)
    except Exception:
        logger.debug("Background folder index rebuild failed for user %s", user_id)


def _auto_place_folder(title: str, content: str, user_id: str) -> str:
    """Find the best existing folder using semantic folder search, with content fallback.

    Uses title + content snippet as the query — title is the strongest signal.
    Prefers any folder-index hit over the content-search fallback; only falls back
    when the folder index is empty (cold vault).
    """
    # Title is the strongest placement signal; supplement with content snippet
    query = f"{title} {content[:300]}".replace("\n", " ").strip()
    if not query:
        return ""

    # Folder vector search — always trust it if the index has any folders
    try:
        folder_results = search_folders(query, user_id, limit=3)
        if not folder_results:
            # Cold start: build index and retry once
            count = rebuild_folder_index(user_id)
            if count > 0:
                folder_results = search_folders(query, user_id, limit=3)

        if folder_results:
            # Always prefer the top-ranked existing folder over inventing one.
            # A low score (e.g. 0.15) still beats a content-search guess.
            top = folder_results[0]
            logger.debug(
                "Folder placement: '%s' (score %.3f)", top["folder"], top["score"]
            )
            return top["folder"]
    except Exception:
        logger.debug("Folder vector search failed, falling back to content search")

    # Fallback: vault is empty or index unavailable — find most common folder
    # among semantically similar notes.
    from collections import Counter

    try:
        results = search(query, limit=10, user_id=user_id)
    except Exception:
        return ""

    folder_counts: Counter = Counter()
    for r in results:
        sp = r.get("source_path", "")
        if "/" in sp:
            folder = sp.rsplit("/", 1)[0]
            if folder.startswith("/vault/"):
                folder = folder[7:]
            folder_counts[folder] += 1

    if not folder_counts:
        return ""

    return folder_counts.most_common(1)[0][0]
