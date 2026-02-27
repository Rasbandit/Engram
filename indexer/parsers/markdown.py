"""Markdown parser: extracts frontmatter, chunks by headings, preserves wikilinks."""

import re
from dataclasses import dataclass, field
from pathlib import Path

import frontmatter
import tiktoken

HEADING_RE = re.compile(r"^(#{1,6})\s+(.+)$", re.MULTILINE)
WIKILINK_RE = re.compile(r"\[\[([^\]|]+)(?:\|[^\]]+)?\]\]")

_enc = tiktoken.get_encoding("cl100k_base")


@dataclass
class Chunk:
    text: str
    metadata: dict = field(default_factory=dict)


def _count_tokens(text: str) -> int:
    return len(_enc.encode(text))


def _split_by_headings(body: str) -> list[tuple[list[str], str]]:
    """Split markdown body into sections by headings.

    Returns list of (heading_path, section_text) tuples.
    heading_path is the accumulated heading hierarchy, e.g. ["Health", "Blood Work", "Iron Panel"].
    """
    sections: list[tuple[list[str], str]] = []
    heading_stack: list[tuple[int, str]] = []  # (level, text)
    current_lines: list[str] = []
    current_heading_path: list[str] = []

    for line in body.split("\n"):
        m = HEADING_RE.match(line)
        if m:
            # Flush current section
            if current_lines:
                text = "\n".join(current_lines).strip()
                if text:
                    sections.append((list(current_heading_path), text))
                current_lines = []

            level = len(m.group(1))
            heading_text = m.group(2).strip()

            # Pop headings at same or deeper level
            while heading_stack and heading_stack[-1][0] >= level:
                heading_stack.pop()

            heading_stack.append((level, heading_text))
            current_heading_path = [h[1] for h in heading_stack]
            current_lines.append(line)
        else:
            current_lines.append(line)

    # Flush final section
    if current_lines:
        text = "\n".join(current_lines).strip()
        if text:
            sections.append((list(current_heading_path), text))

    return sections


def _chunk_text(text: str, max_tokens: int = 512, overlap_tokens: int = 50) -> list[str]:
    """Split text into token-bounded chunks with overlap."""
    tokens = _enc.encode(text)
    if len(tokens) <= max_tokens:
        return [text]

    chunks = []
    start = 0
    while start < len(tokens):
        end = min(start + max_tokens, len(tokens))
        chunk_tokens = tokens[start:end]
        chunks.append(_enc.decode(chunk_tokens))
        if end >= len(tokens):
            break
        start = end - overlap_tokens

    return chunks


def extract_wikilinks(text: str) -> list[str]:
    return WIKILINK_RE.findall(text)


def parse_markdown(file_path: Path, collection: str = "obsidian") -> list[Chunk]:
    """Parse a markdown file into chunks with metadata."""
    raw = file_path.read_text(encoding="utf-8", errors="replace")
    post = frontmatter.loads(raw)

    fm = post.metadata or {}
    title = fm.get("title") or file_path.stem
    tags = fm.get("tags", [])
    if isinstance(tags, str):
        tags = [t.strip() for t in tags.split(",")]
    aliases = fm.get("aliases", [])
    if isinstance(aliases, str):
        aliases = [aliases]

    body = post.content
    sections = _split_by_headings(body)

    if not sections:
        # File has no headings — treat entire body as one section
        sections = [([], body)]

    chunks: list[Chunk] = []
    chunk_index = 0

    for heading_path, section_text in sections:
        heading_str = " > ".join([title] + heading_path) if heading_path else title
        wikilinks = extract_wikilinks(section_text)

        sub_chunks = _chunk_text(section_text)
        for sub in sub_chunks:
            chunks.append(Chunk(
                text=sub,
                metadata={
                    "source_path": str(file_path),
                    "title": title,
                    "heading_path": heading_str,
                    "tags": tags,
                    "aliases": aliases,
                    "wikilinks": wikilinks,
                    "last_modified": file_path.stat().st_mtime,
                    "doc_type": "markdown",
                    "collection": collection,
                    "chunk_index": chunk_index,
                },
            ))
            chunk_index += 1

    return chunks
