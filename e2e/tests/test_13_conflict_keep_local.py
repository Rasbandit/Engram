"""Test 13: Conflict resolved with keep-local — B's version pushed back to server."""

import pytest

from helpers.conflict import setup_conflict
from helpers.vault import read_note


@pytest.mark.asyncio
async def test_conflict_keep_local(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """Both edit same note. B resolves with keep-local → B's version wins everywhere."""
    path = "E2E/ConflictKeepLocal.md"

    await setup_conflict(
        path, vault_a, vault_b, cdp_b, api_sync,
        b_edit="Edited by B — should win",
    )

    # Override B's handler to keep-local
    await cdp_b.override_conflict_handler("keep-local")

    # Resume sync BEFORE pull so keep-local can push B's version
    await cdp_b.resume_outgoing_sync()

    # B pulls — conflict detected, resolved as keep-local → pushes B's version
    await cdp_b.trigger_pull()

    # B's file should still have B's content
    b_content = read_note(vault_b, path)
    assert "Edited by B" in b_content, "B should keep its local version"

    # Server should now have B's version (keep-local pushes to server)
    api_sync.wait_for_note_content(path, "Edited by B", timeout=10)

    # Cleanup
    await cdp_b.restore_conflict_handler()
