"""Test 34: Folder rename propagates — notes appear at new paths on B.

A creates notes in a folder. Server-side folder rename moves all notes
(in-place path update, no soft-delete of old path). B syncs and sees
notes under the new folder path.

Old-path cleanup (test_folder_rename_old_paths_cleaned) is marked
xfail(strict=True): the server renames paths in place without emitting
delete events, so the plugin retains stale files at old paths. This is a
known user-visible bug that BLOCKS shipping folder rename as complete.
Fix: emit explicit delete events for old paths, or add manifest-based
reconciliation to prune stale local files.
"""

import pytest

from helpers.vault import wait_for_file, write_note


@pytest.mark.asyncio
async def test_folder_rename_new_paths(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """Renaming a folder makes notes appear at new paths for B."""
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

    # B syncs — should see new paths
    await cdp_b.trigger_full_sync()
    wait_for_file(vault_b, new_note1, timeout=15)
    wait_for_file(vault_b, new_note2, timeout=15)


@pytest.mark.xfail(
    strict=True,
    reason="BLOCKS SHIP: Server renames paths in place (no delete event) — plugin "
           "has no signal to remove old files. Must emit delete events for old paths "
           "or add manifest-based reconciliation before shipping folder rename.",
)
@pytest.mark.asyncio
async def test_folder_rename_old_paths_cleaned(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """After folder rename, old paths should be removed from B's vault."""
    old_folder = "E2E/RenameCleanup34"
    new_folder = "E2E/RenamedCleanup34"
    note = f"{old_folder}/Cleanup.md"

    write_note(vault_a, note, "# Cleanup Test\nShould be removed at old path")
    api_sync.wait_for_note(note, timeout=10)
    await cdp_b.trigger_full_sync()
    assert (vault_b / note).exists(), "B should have note before rename"

    # Rename folder
    api_sync.rename_folder(old_folder, new_folder)
    api_sync.wait_for_note(f"{new_folder}/Cleanup.md", timeout=10)

    # Multiple syncs to give plugin every chance
    await cdp_b.trigger_full_sync()
    await cdp_b.trigger_full_sync()

    # Old path should be gone (this currently fails — documents the gap)
    assert not (vault_b / note).exists(), "B should not have old path after folder rename"
