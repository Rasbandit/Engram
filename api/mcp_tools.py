"""MCP tool definitions for EDI-Brain, calling search/notes in-process."""

import logging

from fastmcp import FastMCP

from search import search
from notes import get_all_tags, get_note_by_path

logger = logging.getLogger("brain-mcp")

mcp = FastMCP("EDI-Brain")


@mcp.tool()
def search_notes(query: str, limit: int = 5, tags: list[str] | None = None) -> str:
    """Search the Obsidian vault knowledge base. Returns relevant notes ranked by relevance.

    Args:
        query: Natural language search query
        limit: Maximum number of results (1-20, default 5)
        tags: Optional list of tags to filter by (e.g. ["health", "supplements"])
    """
    results = search(query, limit=min(limit, 20), tags=tags)

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
    """Get the full content of a specific note from the knowledge base.

    Args:
        source_path: The source path of the note (e.g. /vault/2. Knowledge Vault/Health/Omega Oils.md)
    """
    data = get_note_by_path(source_path)

    if data is None:
        return f"Note not found: {source_path}"

    lines = [f"# {data.get('title', 'Untitled')}"]
    if data.get("tags"):
        lines.append(f"**Tags:** {', '.join(data['tags'])}")
    lines.append(f"**Source:** {data['source_path']}\n")

    for chunk in data.get("chunks", []):
        if chunk.get("heading_path"):
            lines.append(f"*{chunk['heading_path']}*")
        lines.append(chunk["text"])
        lines.append("")

    return "\n".join(lines)


@mcp.tool()
def list_tags() -> str:
    """List all tags in the knowledge base with document counts."""
    tags = get_all_tags()

    if not tags:
        return "No tags found."

    lines = ["| Tag | Count |", "|-----|-------|"]
    for t in tags:
        lines.append(f"| {t['name']} | {t['count']} |")

    return "\n".join(lines)
