"""Test 04: A modifies a file → updated content propagates to B."""

import pytest

from helpers.vault import read_note, write_note


@pytest.mark.asyncio
async def test_modify_propagation(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """A edits an existing synced note, B receives the update."""
    path = "E2E/ModifyTest.md"

    # A creates initial version
    write_note(vault_a, path, "# Modify Test\nVersion 1")
    api_sync.wait_for_note(path, timeout=10)

    # Sync to B
    await cdp_b.trigger_full_sync()
    assert "Version 1" in read_note(vault_b, path)

    # A modifies the note
    write_note(vault_a, path, "# Modify Test\nVersion 2 — updated by A")

    # Poll server until update lands
    api_sync.wait_for_note_content(path, "Version 2", timeout=10)

    # B pulls the update
    await cdp_b.trigger_full_sync()

    b_content = read_note(vault_b, path)
    assert "Version 2" in b_content, "B did not receive A's modification"
