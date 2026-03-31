"""Test 23: SSE disconnect → reconnect → catch-up pull.

When the SSE stream drops, the plugin should auto-reconnect (exponential
backoff starting at 1s). On reconnect, onStatusChange(true) triggers a
catch-up pull that fetches any changes missed while disconnected.
"""

import asyncio

import pytest

from helpers.vault import wait_for_file, write_note


@pytest.mark.asyncio
async def test_sse_reconnect_catches_up(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """SSE drops, A creates note, SSE reconnects, B gets the note."""
    path = "E2E/SSEReconnect.md"

    # Verify SSE is connected on B
    assert await cdp_b.check_sse_connected(), "B's SSE should be connected"

    # Disconnect B's SSE stream
    await cdp_b.disconnect_sse()
    await asyncio.sleep(0.3)
    assert not await cdp_b.check_sse_connected(), "B's SSE should be disconnected"

    # A creates a note while B's SSE is down
    write_note(vault_a, path, "# SSE Reconnect Test\nCreated while B was disconnected")
    api_sync.wait_for_note(path, timeout=10)

    # Reconnect B's SSE — triggers catch-up pull (main.ts:354)
    await cdp_b.reconnect_sse()

    # Wait for catch-up pull to deliver the note
    b_content = wait_for_file(vault_b, path, timeout=15)
    assert "Created while B was disconnected" in b_content, (
        f"B should have received the note via catch-up pull, got: {b_content[:200]}"
    )
