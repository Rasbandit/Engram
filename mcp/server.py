"""brain-mcp: MCP server that wraps brain-api for Claude Code."""

import json
import logging
import os

import httpx
from mcp.server.fastmcp import FastMCP

logging.basicConfig(
    level=getattr(logging, os.environ.get("LOG_LEVEL", "INFO")),
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("brain-mcp")

BRAIN_API_URL = os.environ.get("BRAIN_API_URL", "http://localhost:8000")
PORT = int(os.environ.get("PORT", "8001"))

_http = httpx.Client(timeout=30.0)

mcp = FastMCP("EDI-Brain", host="0.0.0.0", port=PORT)


@mcp.tool()
def search_notes(query: str, limit: int = 5, tags: list[str] | None = None) -> str:
    """Search the Obsidian vault knowledge base. Returns relevant notes ranked by relevance.

    Args:
        query: Natural language search query
        limit: Maximum number of results (1-20, default 5)
        tags: Optional list of tags to filter by (e.g. ["health", "supplements"])
    """
    resp = _http.post(
        f"{BRAIN_API_URL}/search",
        json={"query": query, "limit": min(limit, 20), "tags": tags},
    )
    resp.raise_for_status()
    data = resp.json()

    # Format results for Claude
    lines = []
    for i, r in enumerate(data["results"], 1):
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
    resp = _http.get(
        f"{BRAIN_API_URL}/note",
        params={"source_path": source_path},
    )
    resp.raise_for_status()
    data = resp.json()

    if "error" in data:
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
    resp = _http.get(f"{BRAIN_API_URL}/tags")
    resp.raise_for_status()
    data = resp.json()

    tags = data.get("tags", [])
    if not tags:
        return "No tags found."

    lines = ["| Tag | Count |", "|-----|-------|"]
    for t in tags:
        lines.append(f"| {t['name']} | {t['count']} |")

    return "\n".join(lines)


if __name__ == "__main__":
    logger.info("Starting brain-mcp on port %d", PORT)
    logger.info("Brain API URL: %s", BRAIN_API_URL)
    mcp.run(transport="sse")
