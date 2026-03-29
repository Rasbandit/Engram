"""Test 02: A creates note → B receives via SSE without manual pull."""

import pytest

from helpers.vault import wait_for_file, write_note


@pytest.mark.asyncio
async def test_sse_live_sync(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """A creates note, B receives it through SSE — no manual pull triggered."""
    path = "E2E/SSELiveTest.md"
    content = "# SSE Live Test\nThis should arrive via server-sent events."

    # Verify SSE is connected on B
    sse_ok = await cdp_b.check_sse_connected()
    assert sse_ok, "B's SSE stream is not connected"

    # A creates the note
    write_note(vault_a, path, content)

    # Wait for A's push to land on server
    api_sync.wait_for_note(path, timeout=10)

    # B should receive via SSE — poll for file (no manual pull!)
    b_content = wait_for_file(vault_b, path, timeout=15)
    assert "SSE Live Test" in b_content, "B did not receive A's note via SSE"
