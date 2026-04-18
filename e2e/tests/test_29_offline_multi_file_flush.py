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
            time.sleep(0.3)

        # Wait for EACH path to appear in the queue. Under xdist with 2 workers,
        # Obsidian's file-watch → push-attempt → queue cycle can exceed 10s for
        # the last-written file; 30s matches the drain timeout below.
        paths_set = set(paths)
        deadline = time.monotonic() + 30
        queued_paths: set[str] = set()

        while time.monotonic() < deadline:
            entries = await cdp_a.get_queue_entries()
            queued_paths = {e["path"] for e in entries}
            if paths_set.issubset(queued_paths):
                break
            await asyncio.sleep(0.5)

        missing = paths_set - queued_paths
        assert not missing, (
            f"Expected all 3 paths queued within 30s. Missing: {sorted(missing)}. "
            f"Queued entries: {await cdp_a.get_queue_entries()}"
        )
    finally:
        # MUST restore even if assertions fail — prevents cascade to later tests
        await cdp_a.restore_online()
        # 30s accommodates backend load when xdist runs two workers in parallel.
        await cdp_a.wait_for_queue_drain(timeout=30)

    # All 3 notes should be on server
    for path in paths:
        note = api_sync.wait_for_note(path, timeout=10)
        assert note is not None, f"{path} should be on server"

    assert await cdp_a.get_queue_size() == 0, "Queue should be empty after flush"
