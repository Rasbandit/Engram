"""Test 29: Multiple files queued offline → all flushed to server.

Verifies that the queue correctly handles multiple distinct files and
flushes them all when connectivity returns.
"""

import asyncio
import time

import pytest

from helpers.vault import write_note


@pytest.mark.asyncio
async def test_offline_multi_file_flush(vault_a, cdp_a, api_sync):
    """3 different files queued while offline → all reach server after recovery."""
    paths = [
        "E2E/MultiFlush1.md",
        "E2E/MultiFlush2.md",
        "E2E/MultiFlush3.md",
    ]

    # Ensure clean state
    await cdp_a.clear_queue()

    # Simulate offline
    await cdp_a.simulate_offline()
    await asyncio.sleep(0.3)

    try:
        # Create 3 files with spacing for separate push attempts
        for i, path in enumerate(paths, 1):
            write_note(vault_a, path, f"# Multi Flush {i}\nCreated while offline")
            time.sleep(0.7)

        # Wait for push attempts to fail and queue
        await asyncio.sleep(3)

        queue_size = await cdp_a.get_queue_size()
        assert queue_size >= 3, (
            f"Expected at least 3 queued entries, got {queue_size}. "
            f"Entries: {await cdp_a.get_queue_entries()}"
        )
    finally:
        # MUST restore even if assertions fail — prevents cascade to later tests
        await cdp_a.restore_online()
        await asyncio.sleep(5)

    # All 3 notes should be on server
    for path in paths:
        note = api_sync.wait_for_note(path, timeout=10)
        assert note is not None, f"{path} should be on server"

    assert await cdp_a.get_queue_size() == 0, "Queue should be empty after flush"
