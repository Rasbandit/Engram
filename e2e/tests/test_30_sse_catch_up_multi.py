"""Test 30: SSE catch-up pull covers multiple missed changes.

When SSE reconnects after a gap, the onStatusChange(true) callback in
main.ts triggers a pull() that fetches ALL changes since the last sync
cursor — not just the latest one. This test creates multiple notes while
SSE is down and verifies all are delivered on reconnect.
"""

import asyncio

import pytest

from helpers.vault import wait_for_file, write_note


@pytest.mark.asyncio
async def test_sse_catch_up_multi(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """SSE drops, A creates 3 notes, SSE reconnects, B gets all 3."""
    paths = [
        "E2E/SSECatchUp1.md",
        "E2E/SSECatchUp2.md",
        "E2E/SSECatchUp3.md",
    ]

    # Disconnect B's SSE
    await cdp_b.disconnect_sse()
    await asyncio.sleep(0.3)
    assert not await cdp_b.check_sse_connected(), "B's SSE should be disconnected"

    # A creates 3 notes while B's SSE is down
    for i, path in enumerate(paths, 1):
        write_note(vault_a, path, f"# SSE Catch Up {i}\nMissed by B's SSE")

    # Wait for all to reach server
    for path in paths:
        api_sync.wait_for_note(path, timeout=10)

    # Reconnect B's SSE — triggers catch-up pull
    await cdp_b.reconnect_sse()

    # All 3 should arrive in B's vault via catch-up pull
    for path in paths:
        b_content = wait_for_file(vault_b, path, timeout=15)
        assert "Missed by B's SSE" in b_content, (
            f"{path} not received after SSE catch-up: {b_content[:200]}"
        )
