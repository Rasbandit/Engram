"""Test 06: A and B both edit same note → conflict → keep-both creates copy.

Key insight: B's outgoing sync must be paused before the local edit,
otherwise B pushes its edit to the server (overwriting A's version)
and no conflict exists when B pulls.
"""

import pytest

from helpers.vault import read_note, write_note, wait_for_file


@pytest.mark.asyncio
async def test_conflict_keep_both(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """Both sides edit the same note. B resolves with keep-both."""
    path = "E2E/ConflictKeepBoth.md"

    # 1. A creates the base note
    write_note(vault_a, path, "# Conflict Test\nBase content")
    api_sync.wait_for_note(path, timeout=10)

    # 2. B pulls so both have the same starting point (syncedHashes recorded)
    await cdp_b.trigger_full_sync()
    assert (vault_b / path).exists(), "B should have the base note"

    # 3. A edits → wait for A's push to land on server
    write_note(vault_a, path, "# Conflict Test\nEdited by A")
    api_sync.wait_for_note_content(path, "Edited by A", timeout=10)

    # 4. Pause B's outgoing sync so its edit stays local-only
    await cdp_b.pause_outgoing_sync()

    # 5. B edits locally (handleModify is no-op, so B won't push)
    write_note(vault_b, path, "# Conflict Test\nEdited by B")

    # 6. Override B's conflict handler to auto-resolve with keep-both
    await cdp_b.override_conflict_handler("keep-both")

    # 7. B pulls — should detect conflict:
    #    local="Edited by B" (hash ≠ syncedHash), server="Edited by A"
    await cdp_b.trigger_pull()

    # 8. Verify: original path still exists with B's local content
    assert (vault_b / path).exists(), "Original path should still exist"
    original = read_note(vault_b, path)
    assert "Edited by B" in original, "Original should keep B's local version"

    # 9. Verify: conflict copy was created with A's (remote) content
    e2e_dir = vault_b / "E2E"
    conflict_files = list(e2e_dir.glob("ConflictKeepBoth (conflict*).md"))
    assert len(conflict_files) >= 1, (
        f"Expected at least 1 conflict copy, found: "
        f"{[f.name for f in e2e_dir.glob('ConflictKeepBoth*')]}"
    )
    conflict_content = conflict_files[0].read_text(encoding="utf-8")
    assert "Edited by A" in conflict_content, "Conflict copy should have A's content"

    # 10. Cleanup: restore handlers
    await cdp_b.restore_conflict_handler()
    await cdp_b.resume_outgoing_sync()
