"""Test 36: Conflict resolved with keep-remote — server version wins.

Completes the conflict resolution coverage: keep-local (13), keep-both (6),
skip (14), merge (7/20), and now keep-remote. After resolution, B's local
file should contain the server (A's) version.
"""

import pytest

from helpers.conflict import setup_conflict
from helpers.vault import read_note


@pytest.mark.asyncio
async def test_conflict_keep_remote(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """Both edit same note. B resolves keep-remote → server (A's) version wins."""
    path = "E2E/ConflictKeepRemote36.md"

    await cdp_b.disconnect_stream()

    try:
        await setup_conflict(
            path, vault_a, vault_b, cdp_b, api_sync,
            a_edit="Edited by A — server version",
            b_edit="Edited by B — should be overwritten",
        )

        # Set B to resolve as keep-remote
        await cdp_b.set_conflict_resolution("modal")
        await cdp_b.override_conflict_handler("keep-remote")

        # B pulls — conflict detected, resolved as keep-remote
        await cdp_b.resume_outgoing_sync()
        await cdp_b.trigger_pull()

        # B's file should now have A's (server) content
        b_content = read_note(vault_b, path)
        assert "Edited by A" in b_content, (
            f"B should have server version after keep-remote, got: {b_content[:200]}"
        )
        assert "Edited by B" not in b_content, (
            "B's local version should be overwritten by keep-remote"
        )

        # Server should still have A's version (unchanged)
        server_note = api_sync.get_note(path)
        assert "Edited by A" in server_note["content"], "Server should retain A's version"
    finally:
        await cdp_b.reconnect_stream()
        await cdp_b.restore_conflict_handler()
        await cdp_b.set_conflict_resolution("auto")
