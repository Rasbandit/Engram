"""Test 31: Offline queue survives Obsidian restart.

Queue entries are persisted to data.json. After a hard restart, the plugin
should restore the queue and flush it during the startup sync.

WARNING: This test kills and restarts Obsidian instance A. It should run
last in the test suite (alphabetical ordering ensures this).
"""

import asyncio
import time

import pytest

from helpers.vault import write_note


@pytest.mark.asyncio
async def test_restart_preserves_queue(vault_a, cdp_a, api_sync, obsidian_a):
    """Queue entries persist across Obsidian restart and flush on startup."""
    path1 = "E2E/RestartQueue1.md"
    path2 = "E2E/RestartQueue2.md"

    # 1. Simulate offline on A
    await cdp_a.simulate_offline()
    await asyncio.sleep(0.3)

    # 2. Create 2 files → push fails → queued
    write_note(vault_a, path1, "# Restart Queue 1\nSurvives restart")
    time.sleep(0.7)
    write_note(vault_a, path2, "# Restart Queue 2\nAlso survives restart")

    # Wait for push attempts + queueing
    await asyncio.sleep(3)
    queue_size = await cdp_a.get_queue_size()
    assert queue_size >= 2, f"Expected at least 2 queued, got {queue_size}"

    # 3. Force persist queue to data.json (bypass debounce)
    await cdp_a.evaluate("""
        (async function() {
            const plugin = app.plugins.plugins['engram-sync'];
            await plugin.saveData({
                settings: plugin.settings,
                lastSync: plugin.syncEngine.getLastSync(),
                offlineQueue: plugin.syncEngine.queue.all(),
                syncState: plugin.syncEngine.exportSyncState(),
                syncedHashes: plugin.syncEngine.exportHashes(),
            });
            return 'saved';
        })()
    """, await_promise=True)

    # 4. Kill Obsidian A (hard stop — simulates crash)
    obsidian_a.stop()
    await asyncio.sleep(2)

    # 5. Restart Obsidian A (restart=True preserves vault + data.json with queue)
    await obsidian_a.async_start(restart=True)
    await cdp_a.wait_for_plugin_ready(timeout=60)

    # 6. Startup sync should restore queue and flush it
    #    Give it time for initial sync to complete
    await asyncio.sleep(10)

    # 7. Both notes should now be on server
    note1 = api_sync.get_note(path1)
    note2 = api_sync.get_note(path2)

    assert note1 is not None, f"{path1} should be on server after restart"
    assert note2 is not None, f"{path2} should be on server after restart"
    assert "Survives restart" in note1["content"]
    assert "Also survives restart" in note2["content"]
