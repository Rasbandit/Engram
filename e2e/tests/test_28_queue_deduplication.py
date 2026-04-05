"""Test 28: Multiple offline edits to the same file → only latest synced.

The offline queue deduplicates by path: newer entries replace older ones.
After recovery, only the final version should reach the server.
"""

import asyncio
import time

import pytest

from helpers.vault import write_note


@pytest.mark.asyncio
async def test_queue_deduplication(vault_a, cdp_a, api_sync):
    """5 edits to same file while offline → deduped → server gets final version."""
    path = "E2E/QueueDedup.md"

    # Ensure clean state — no leftover queue entries from previous tests
    await cdp_a.clear_queue()

    # Simulate offline
    await cdp_a.simulate_offline()
    await asyncio.sleep(0.3)

    try:
        # Write the file 5 times with different content.
        # debounceMs is 500ms in e2e config, so space writes > debounce to ensure
        # each triggers a separate push attempt (all fail → enqueue → dedup).
        for i in range(1, 6):
            write_note(vault_a, path, f"# Queue Dedup\nVersion {i}")
            time.sleep(0.7)

        # Wait for all push attempts to fail and queue
        await asyncio.sleep(3)

        # Queue deduplicates by path (Map keyed by path). Should be 1 entry,
        # but timing between debounce fires can occasionally produce 2 if a
        # race between Obsidian's create+modify events splits the first write.
        queue_size = await cdp_a.get_queue_size()
        entries = await cdp_a.get_queue_entries()
        dedup_paths = {e["path"] for e in entries}
        assert len(dedup_paths) == 1, (
            f"Queue should only contain entries for one path, "
            f"got {len(dedup_paths)}: {entries}"
        )
        assert queue_size <= 2, (
            f"Expected at most 2 queued entries (dedup by path), "
            f"got {queue_size}: {entries}"
        )
    finally:
        # MUST restore online even if assertions fail — otherwise test_29+ cascade
        await cdp_a.restore_online()
        await asyncio.sleep(3)

    # Server should have the FINAL version
    note = api_sync.wait_for_note(path, timeout=10)
    assert "Version 5" in note["content"], (
        f"Server should have final version, got: {note['content'][:200]}"
    )
    assert await cdp_a.get_queue_size() == 0, "Queue should be empty"
