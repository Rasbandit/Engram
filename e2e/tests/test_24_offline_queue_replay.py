"""Test 24: Push failure → offline queue → recovery → flush.

When pushes fail (network error), changes are queued in the offline queue.
When connectivity returns, the queue is flushed oldest-first and all
changes reach the server.
"""

import asyncio
import time

import pytest

from helpers.vault import write_note


@pytest.mark.asyncio
async def test_offline_queue_replay(vault_a, cdp_a, api_sync):
    """Push fails → queued → restore → flushed to server."""
    path1 = "E2E/OfflineQueue1.md"
    path2 = "E2E/OfflineQueue2.md"

    # Simulate network failure on A
    await cdp_a.simulate_offline()
    await asyncio.sleep(0.3)

    # Write 2 files — push attempts will fail and enqueue
    write_note(vault_a, path1, "# Offline Note 1\nQueued while offline")
    time.sleep(0.7)  # Space apart to ensure separate push attempts
    write_note(vault_a, path2, "# Offline Note 2\nAlso queued while offline")

    # Wait for push attempts to fail and queue
    await asyncio.sleep(3)

    # Verify offline state
    assert await cdp_a.get_offline_status(), "Engine should be offline"
    queue_size = await cdp_a.get_queue_size()
    assert queue_size >= 2, f"Expected at least 2 queued entries, got {queue_size}"

    # Restore connectivity
    await cdp_a.restore_online()

    # Wait for queue flush
    await asyncio.sleep(3)

    # Verify both notes reached the server
    api_sync.wait_for_note(path1, timeout=10)
    api_sync.wait_for_note(path2, timeout=10)

    # Queue should be empty
    assert await cdp_a.get_queue_size() == 0, "Queue should be empty after flush"
