"""Test 06: A and B both edit same note → conflict → keep-both creates copy.

Key insight: B's outgoing sync must be paused before the local edit,
otherwise B pushes its edit to the server (overwriting A's version)
and no conflict exists when B pulls.
"""

import pytest

from helpers.conflict import setup_conflict
from helpers.vault import read_note


@pytest.mark.asyncio
async def test_conflict_keep_both(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """Both sides edit the same note. B resolves with keep-both."""
    path = "E2E/ConflictKeepBoth.md"

    await setup_conflict(path, vault_a, vault_b, cdp_b, api_sync)

    # Override B's conflict handler to auto-resolve with keep-both
    await cdp_b.override_conflict_handler("keep-both")

    # B pulls — should detect conflict:
    #   local="Edited by B" (hash ≠ syncedHash), server="Edited by A"
    await cdp_b.trigger_pull()

    # Verify: original path still exists with B's local content
    assert (vault_b / path).exists(), "Original path should still exist"
    original = read_note(vault_b, path)
    assert "Edited by B" in original, "Original should keep B's local version"

    # Verify: exactly 1 conflict copy was created with A's (remote) content
    e2e_dir = vault_b / "E2E"
    conflict_files = list(e2e_dir.glob("ConflictKeepBoth (conflict*).md"))
    assert len(conflict_files) == 1, (
        f"Expected exactly 1 conflict copy, found {len(conflict_files)}: "
        f"{[f.name for f in e2e_dir.glob('ConflictKeepBoth*')]}"
    )
    conflict_content = conflict_files[0].read_text(encoding="utf-8")
    assert "Edited by A" in conflict_content, "Conflict copy should have A's content"

    # Cleanup: restore handlers
    await cdp_b.restore_conflict_handler()
    await cdp_b.resume_outgoing_sync()
