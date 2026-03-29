"""Test 14: Conflict resolved with skip — no changes applied to either side."""

import pytest

from helpers.vault import read_note, write_note


@pytest.mark.asyncio
async def test_conflict_skip(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """Both edit same note. B resolves with skip → nothing changes."""
    path = "E2E/ConflictSkip.md"

    # 1. A creates base note
    write_note(vault_a, path, "# Conflict Test\nBase content")
    api_sync.wait_for_note(path, timeout=10)

    # 2. B pulls to establish synced state
    await cdp_b.trigger_full_sync()
    assert (vault_b / path).exists()

    # 3. A edits → push to server
    write_note(vault_a, path, "# Conflict Test\nEdited by A")
    api_sync.wait_for_note_content(path, "Edited by A", timeout=10)

    # 4. Pause B's outgoing sync
    await cdp_b.pause_outgoing_sync()

    # 5. B edits locally
    write_note(vault_b, path, "# Conflict Test\nEdited by B")

    # 6. Override B's handler to skip
    await cdp_b.override_conflict_handler("skip")

    # 7. B pulls — conflict detected, resolved as skip → no changes
    await cdp_b.trigger_pull()

    # 8. B should still have B's local content (skip doesn't overwrite)
    b_content = read_note(vault_b, path)
    assert "Edited by B" in b_content, "Skip should preserve B's local content"

    # 9. Server should still have A's content (skip doesn't push)
    note = api_sync.get_note(path)
    assert "Edited by A" in note["content"], "Skip should leave server unchanged"

    # 10. Cleanup
    await cdp_b.restore_conflict_handler()
    await cdp_b.resume_outgoing_sync()
