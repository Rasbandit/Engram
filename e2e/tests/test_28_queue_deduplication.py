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
    """5 edits to same file while offline → queue has 1 entry → server gets final."""
    path = "E2E/QueueDedup.md"

    # Simulate offline
    await cdp_a.simulate_offline()
    await asyncio.sleep(0.3)

    # Write the file 5 times with different content
    for i in range(1, 6):
        write_note(vault_a, path, f"# Queue Dedup\nVersion {i}")
        time.sleep(0.7)  # Space apart for separate push attempts

    # Wait for all push attempts to fail and queue
    await asyncio.sleep(3)

    # Queue should have exactly 1 entry for this path (dedup)
    queue_size = await cdp_a.get_queue_size()
    assert queue_size == 1, (
        f"Expected 1 queued entry (dedup by path), got {queue_size}"
    )

    # Restore connectivity and flush
    await cdp_a.restore_online()
    await asyncio.sleep(3)

    # Server should have the FINAL version
    note = api_sync.wait_for_note(path, timeout=10)
    assert "Version 5" in note["content"], (
        f"Server should have final version, got: {note['content'][:200]}"
    )
    assert await cdp_a.get_queue_size() == 0, "Queue should be empty"
