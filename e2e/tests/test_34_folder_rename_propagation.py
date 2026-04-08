"""Test 34: Folder rename propagates — notes move to new folder on B.

A creates notes in a folder. Server-side folder rename moves all notes.
B syncs and sees notes under the new folder path.
"""

import pytest

from helpers.vault import wait_for_file, wait_for_file_gone, write_note


@pytest.mark.asyncio
async def test_folder_rename_propagation(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """Renaming a folder moves all contained notes for B."""
    old_folder = "E2E/RenameFolder34"
    new_folder = "E2E/RenamedFolder34"
    note1 = f"{old_folder}/Note1.md"
    note2 = f"{old_folder}/Note2.md"

    # A creates two notes in the folder
    write_note(vault_a, note1, "# Note 1\nIn old folder")
    write_note(vault_a, note2, "# Note 2\nIn old folder")
    api_sync.wait_for_note(note1, timeout=10)
    api_sync.wait_for_note(note2, timeout=10)

    # B syncs to establish state
    await cdp_b.trigger_full_sync()
    assert (vault_b / note1).exists(), "B should have Note1 before rename"
    assert (vault_b / note2).exists(), "B should have Note2 before rename"

    # Rename folder via API
    status = api_sync.rename_folder(old_folder, new_folder)
    assert status == 200, f"Folder rename should succeed, got {status}"

    # Verify server moved notes
    new_note1 = f"{new_folder}/Note1.md"
    new_note2 = f"{new_folder}/Note2.md"
    api_sync.wait_for_note(new_note1, timeout=10)
    api_sync.wait_for_note(new_note2, timeout=10)

    # B syncs — should see new paths (may need two rounds: one for
    # new notes, one for old path deletions in the changes feed)
    await cdp_b.trigger_full_sync()
    wait_for_file(vault_b, new_note1, timeout=15)
    wait_for_file(vault_b, new_note2, timeout=15)

    # Second sync to pick up deletions at old paths
    await cdp_b.trigger_full_sync()

    # Old paths should be gone on B
    wait_for_file_gone(vault_b, note1, timeout=15)
    wait_for_file_gone(vault_b, note2, timeout=15)
