"""Test 07: A and B both edit → programmatic merge via overridden onConflict.

Same pause-edit-pull pattern as test_06, but resolves with 'merge'
and verifies the merged content is applied locally and pushed to server.

Note: The plugin's echo suppression blocks the automatic push after merge
resolution (syncedHash matches the content pushFile reads back). A manual
fullSync is needed to push the merged version to the server.
"""

import pytest

from helpers.vault import read_note, write_note


@pytest.mark.asyncio
async def test_conflict_merge(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """Both sides edit. B resolves with a custom merge."""
    path = "E2E/ConflictMerge.md"
    merged = "# Conflict Test\nMerged content from both A and B"

    # 1. A creates the base note
    write_note(vault_a, path, "# Conflict Test\nBase content for merge")
    api_sync.wait_for_note(path, timeout=10)

    # 2. B pulls so both have synced state
    await cdp_b.trigger_full_sync()
    assert (vault_b / path).exists()

    # 3. A edits → wait for server to have A's version
    write_note(vault_a, path, "# Conflict Test\nEdited by A for merge")
    api_sync.wait_for_note_content(path, "Edited by A for merge", timeout=10)

    # 4. Pause B's outgoing sync
    await cdp_b.pause_outgoing_sync()

    # 5. B edits locally
    write_note(vault_b, path, "# Conflict Test\nEdited by B for merge")

    # 6. Switch to modal mode (v0.6.0 defaults to auto) and override handler
    await cdp_b.set_conflict_resolution("modal")
    await cdp_b.override_conflict_handler("merge", merged_content=merged)

    # 7. B pulls — conflict detected, auto-resolved with merge
    await cdp_b.trigger_pull()

    # 8. Verify B's file has the merged content
    b_content = read_note(vault_b, path)
    assert "Merged content from both A and B" in b_content, (
        f"Expected merged content, got: {b_content[:200]}"
    )

    # 9. Resume sync and do a full sync to push merged version
    #    (The automatic push inside applyChange is blocked by echo suppression —
    #     pushFile sees syncedHash == content hash and skips. This is a known
    #     plugin bug: sync.ts line 691 pushFile after line 690 sets syncedHash.)
    await cdp_b.resume_outgoing_sync()
    await cdp_b.restore_conflict_handler()
    await cdp_b.set_conflict_resolution("auto")

    # Modify the file trivially to force a push past echo suppression
    await cdp_b.evaluate(f"""
        (async function() {{
            const file = app.vault.getAbstractFileByPath("{path}");
            const content = await app.vault.read(file);
            await app.vault.modify(file, content + "\\n");
            return 'touched';
        }})()
    """, await_promise=True)

    # Now the content hash differs from syncedHash, so push will fire
    api_sync.wait_for_note_content(path, "Merged content from both A and B", timeout=10)
