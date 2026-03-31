"""Test 27: Empty markdown file syncs correctly between devices.

Edge case: a zero-content .md file should push, pull, and then accept
edits that propagate normally.
"""

import pytest

from helpers.vault import read_note, wait_for_file, write_note


@pytest.mark.asyncio
async def test_empty_note_sync(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """Empty note pushes to server and pulls to B, then edits propagate."""
    path = "E2E/EmptyNote.md"

    # A creates an empty markdown file
    write_note(vault_a, path, "")
    api_sync.wait_for_note(path, timeout=10)

    # Server should have the note (possibly with empty content)
    note = api_sync.get_note(path)
    assert note is not None, "Empty note should exist on server"

    # B pulls — should get the empty file
    await cdp_b.trigger_full_sync()
    assert (vault_b / path).exists(), "B should have the empty file"
    b_content = read_note(vault_b, path)
    assert b_content.strip() == "" or len(b_content.strip()) == 0, (
        f"B's file should be empty, got: {b_content[:100]}"
    )

    # A edits empty → non-empty
    write_note(vault_a, path, "# No Longer Empty\nThis note has content now.")
    api_sync.wait_for_note_content(path, "No Longer Empty", timeout=10)

    # B pulls the update
    await cdp_b.trigger_full_sync()
    b_content = read_note(vault_b, path)
    assert "No Longer Empty" in b_content, (
        f"B should have updated content, got: {b_content[:200]}"
    )
