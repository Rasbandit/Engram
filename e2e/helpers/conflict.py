"""Shared conflict test setup — used by test_06, test_13, test_14.

Extracts the common 5-step pattern:
1. A creates base note
2. B pulls to establish synced state
3. A edits → push to server
4. Pause B's outgoing sync
5. B edits locally
"""

from __future__ import annotations

from helpers.vault import write_note


async def setup_conflict(
    path: str,
    vault_a,
    vault_b,
    cdp_b,
    api_sync,
    *,
    a_edit: str = "Edited by A",
    b_edit: str = "Edited by B",
    base_content: str = "Base content",
):
    """Create a conflict: A and B both edit the same note.

    After this function returns:
    - Server has A's version
    - B has B's version locally (outgoing sync paused)
    - B's syncedHash records the original base, so pull will detect conflict
    """
    # 1. A creates the base note
    write_note(vault_a, path, f"# Conflict Test\n{base_content}")
    api_sync.wait_for_note(path, timeout=10)

    # 2. B pulls to establish synced state (records syncedHash)
    await cdp_b.trigger_full_sync()
    assert (vault_b / path).exists(), "B should have the base note after pull"

    # 3. A edits → push to server
    write_note(vault_a, path, f"# Conflict Test\n{a_edit}")
    api_sync.wait_for_note_content(path, a_edit, timeout=10)

    # 4. Pause B's outgoing sync so B's edit stays local-only
    await cdp_b.pause_outgoing_sync()

    # 5. B edits locally
    write_note(vault_b, path, f"# Conflict Test\n{b_edit}")
