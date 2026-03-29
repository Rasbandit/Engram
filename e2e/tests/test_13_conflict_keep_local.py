"""Test 13: Conflict resolved with keep-local — B's version pushed back to server."""

import pytest

from helpers.vault import read_note, write_note


@pytest.mark.asyncio
async def test_conflict_keep_local(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """Both edit same note. B resolves with keep-local → B's version wins everywhere."""
    path = "E2E/ConflictKeepLocal.md"

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
    write_note(vault_b, path, "# Conflict Test\nEdited by B — should win")

    # 6. Override B's handler to keep-local
    await cdp_b.override_conflict_handler("keep-local")

    # 7. Resume sync BEFORE pull so keep-local can push B's version
    await cdp_b.resume_outgoing_sync()

    # 8. B pulls — conflict detected, resolved as keep-local → pushes B's version
    await cdp_b.trigger_pull()

    # 9. B's file should still have B's content
    b_content = read_note(vault_b, path)
    assert "Edited by B" in b_content, "B should keep its local version"

    # 10. Server should now have B's version (keep-local pushes to server)
    api_sync.wait_for_note_content(path, "Edited by B", timeout=10)

    # 11. Cleanup
    await cdp_b.restore_conflict_handler()
