"""Test 15: Merge resolution should auto-push merged content to server.

This test exposes a known plugin bug: after merge conflict resolution,
the automatic pushFile call (sync.ts:691) is blocked by echo suppression.
Line 690 sets syncedHash to the merged content hash, then line 691 calls
pushFile which reads the file back, sees hash === syncedHash, and skips.

This test SHOULD pass once the bug is fixed (e.g. pushFile(existing, true)
to force past echo suppression). Until then it is marked xfail.
"""

import pytest

from helpers.vault import read_note, write_note


@pytest.mark.xfail(reason="Plugin bug: echo suppression blocks merge auto-push (sync.ts:690-691) — Rasbandit/Engram-obsidian-sync#2")
@pytest.mark.asyncio
async def test_merge_auto_pushes_to_server(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """After merge resolution, server should have merged content WITHOUT manual intervention."""
    path = "E2E/MergeAutoPush.md"
    merged = "# Merge Auto Push\nCombined from A and B"

    # 1. A creates base note
    write_note(vault_a, path, "# Merge Auto Push\nBase content")
    api_sync.wait_for_note(path, timeout=10)

    # 2. B pulls to establish synced state
    await cdp_b.trigger_full_sync()
    assert (vault_b / path).exists()

    # 3. A edits → push to server
    write_note(vault_a, path, "# Merge Auto Push\nEdited by A")
    api_sync.wait_for_note_content(path, "Edited by A", timeout=10)

    # 4. Pause B, edit locally
    await cdp_b.pause_outgoing_sync()
    write_note(vault_b, path, "# Merge Auto Push\nEdited by B")

    # 5. Set merge handler, resume sync so pushFile can work
    await cdp_b.override_conflict_handler("merge", merged_content=merged)
    await cdp_b.resume_outgoing_sync()

    # 6. B pulls — conflict resolved with merge, pushFile should auto-push
    await cdp_b.trigger_pull()

    # 7. Verify local has merged content
    b_content = read_note(vault_b, path)
    assert "Combined from A and B" in b_content

    # 8. Server should have merged content WITHOUT any manual touch/resync
    #    This is where the bug manifests — server still has "Edited by A"
    api_sync.wait_for_note_content(path, "Combined from A and B", timeout=10)

    # Cleanup
    await cdp_b.restore_conflict_handler()
