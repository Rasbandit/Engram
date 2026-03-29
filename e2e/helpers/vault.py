"""Vault file operations for E2E tests."""

from __future__ import annotations

import time
from pathlib import Path


def write_note(vault_path: Path, rel_path: str, content: str) -> None:
    """Write a markdown file to the vault, creating parent dirs as needed."""
    full = vault_path / rel_path
    full.parent.mkdir(parents=True, exist_ok=True)
    full.write_text(content, encoding="utf-8")


def read_note(vault_path: Path, rel_path: str) -> str:
    """Read file content. Raises FileNotFoundError if missing."""
    return (vault_path / rel_path).read_text(encoding="utf-8")


def delete_note(vault_path: Path, rel_path: str) -> None:
    """Delete a file from the vault."""
    full = vault_path / rel_path
    full.unlink(missing_ok=True)


def wait_for_file(
    vault_path: Path, rel_path: str, timeout: float = 15, poll: float = 0.3
) -> str:
    """Poll until file exists, return content. Raise TimeoutError."""
    full = vault_path / rel_path
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if full.exists():
            return full.read_text(encoding="utf-8")
        time.sleep(poll)
    raise TimeoutError(f"File {rel_path} did not appear within {timeout}s")


def wait_for_file_gone(
    vault_path: Path, rel_path: str, timeout: float = 15, poll: float = 0.3
) -> None:
    """Poll until file no longer exists. Raise TimeoutError."""
    full = vault_path / rel_path
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not full.exists():
            return
        time.sleep(poll)
    raise TimeoutError(f"File {rel_path} still exists after {timeout}s")


def wait_for_content(
    vault_path: Path,
    rel_path: str,
    expected: str,
    timeout: float = 15,
    poll: float = 0.3,
) -> str:
    """Poll until file contains expected substring, return full content."""
    full = vault_path / rel_path
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if full.exists():
            content = full.read_text(encoding="utf-8")
            if expected in content:
                return content
        time.sleep(poll)
    raise TimeoutError(
        f"File {rel_path} did not contain '{expected}' within {timeout}s"
    )


def list_notes(vault_path: Path, folder: str = "") -> list[str]:
    """List .md files in folder (relative paths)."""
    search = vault_path / folder if folder else vault_path
    if not search.exists():
        return []
    return sorted(
        str(p.relative_to(vault_path))
        for p in search.rglob("*.md")
        if ".obsidian" not in p.parts and ".trash" not in p.parts
    )
