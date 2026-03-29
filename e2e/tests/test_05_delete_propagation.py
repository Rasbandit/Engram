"""Test 05: A deletes a file → deletion propagates to server and B."""

import pytest

from helpers.vault import delete_note, wait_for_file_gone, write_note


@pytest.mark.asyncio
async def test_delete_propagation(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """A deletes a synced file, B's copy should be removed on next pull."""
    path = "E2E/DeleteTest.md"

    # A creates the note
    write_note(vault_a, path, "# Delete Test\nThis file will be deleted.")
    api_sync.wait_for_note(path, timeout=10)

    # Sync to B
    await cdp_b.trigger_full_sync()
    assert (vault_b / path).exists(), "B should have the note before deletion"

    # A deletes the note
    delete_note(vault_a, path)

    # Poll server until delete propagates (soft-delete → 404)
    api_sync.wait_for_note_gone(path, timeout=10)

    # B pulls — file should be trashed/removed
    await cdp_b.trigger_full_sync()

    # Wait for file to disappear (plugin moves to .trash)
    wait_for_file_gone(vault_b, path, timeout=10)
