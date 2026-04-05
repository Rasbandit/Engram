"""Test 02: A creates note → B receives via WebSocket channel without manual pull."""

import pytest

from helpers.vault import wait_for_file, write_note


@pytest.mark.asyncio
async def test_live_sync(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """A creates note, B receives it through WebSocket channel — no manual pull triggered."""
    path = "E2E/LiveSyncTest.md"
    content = "# Live Sync Test\nThis should arrive via WebSocket channel."

    # Verify channel is connected on B
    connected = await cdp_b.check_stream_connected()
    assert connected, "B's WebSocket channel is not connected"

    # A creates the note
    write_note(vault_a, path, content)

    # Wait for A's push to land on server
    api_sync.wait_for_note(path, timeout=10)

    # B should receive via channel — poll for file (no manual pull!)
    b_content = wait_for_file(vault_b, path, timeout=15)
    assert "Live Sync Test" in b_content, "B did not receive A's note via channel"
