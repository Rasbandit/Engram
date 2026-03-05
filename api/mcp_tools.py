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
from indexing import index_note
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
