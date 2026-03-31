"""Test 21: Overlapping edits → auto conflict file creation.

A and B both edit the same line. The 3-way merge detects overlapping edit
ranges and falls through to conflict resolution. With conflictResolution
set to "auto" (v0.6.0 default), a timestamped conflict file is created
containing the remote version, and the local version is preserved.

Requires v0.6.0+ (BaseStore + auto conflict resolution).
"""

import pytest

from helpers.conflict import setup_conflict
from helpers.vault import list_notes, read_note


@pytest.mark.asyncio
async def test_auto_conflict_file(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """Overlapping edits create a conflict file instead of showing a modal."""
    path = "E2E/AutoConflictFile.md"

    # Ensure auto mode is active (v0.6.0 default, but be explicit)
    await cdp_b.set_conflict_resolution("auto")

    # Setup: A and B both edit the same line (guaranteed overlap)
    await setup_conflict(
        path, vault_a, vault_b, cdp_b, api_sync,
        a_edit="Edited by A — overlapping",
        b_edit="Edited by B — overlapping",
    )

    try:
        # B pulls — 3-way merge detects overlap → auto creates conflict file
        await cdp_b.trigger_pull()

        # Original file should keep B's local version
        b_content = read_note(vault_b, path)
        assert "Edited by B" in b_content, (
            f"Original should keep B's local version, got: {b_content[:200]}"
        )

        # A conflict file should exist with A's (remote) content
        e2e_dir = vault_b / "E2E"
        conflict_files = list(e2e_dir.glob("AutoConflictFile (conflict*).md"))
        assert len(conflict_files) >= 1, (
            f"Expected at least 1 conflict file, found: "
            f"{[f.name for f in e2e_dir.glob('AutoConflictFile*')]}"
        )
        conflict_content = conflict_files[0].read_text(encoding="utf-8")
        assert "Edited by A" in conflict_content, (
            f"Conflict file should have A's remote content, got: {conflict_content[:200]}"
        )
    finally:
        await cdp_b.resume_outgoing_sync()
