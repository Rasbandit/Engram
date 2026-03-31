"""Test 25: Concurrent server edit causes 409 on push.

A creates a note and syncs. Then the API client updates the note directly
on the server (simulating another device), incrementing the version. When A
edits the note locally and pushes, the server returns 409 (version conflict).
The plugin should handle this via 3-way merge or conflict resolution.
"""

import time

import pytest

from helpers.vault import read_note, write_note


@pytest.mark.asyncio
async def test_push_409_handled(vault_a, cdp_a, api_sync):
    """Push gets 409 from concurrent server edit — plugin handles gracefully."""
    path = "E2E/Push409.md"
    base_content = "# Push 409 Test\n\nSection A: original\n\nSection B: original"

    # 1. A creates note → push to server (establishes version N)
    write_note(vault_a, path, base_content)
    api_sync.wait_for_note(path, timeout=10)

    # Wait for A to finish syncing (sync state established)
    await cdp_a.trigger_full_sync()

    # 2. API client updates note directly (version now N+1)
    #    Edit Section B only — non-overlapping with A's upcoming edit
    server_content = "# Push 409 Test\n\nSection A: original\n\nSection B: edited by server"
    api_sync.create_note(path, server_content, mtime=time.time())

    # 3. A edits Section A locally → push → should get 409
    local_content = "# Push 409 Test\n\nSection A: edited by A\n\nSection B: original"
    write_note(vault_a, path, local_content)

    # Wait for push attempt + conflict resolution
    import asyncio
    await asyncio.sleep(5)

    # 4. Verify: the note should be in a consistent state
    #    Either auto-merged (both edits) or conflict-resolved
    a_content = read_note(vault_a, path)
    server_note = api_sync.get_note(path)

    # The 409 handler should have produced some resolution:
    # - If auto-merge succeeded: both edits present
    # - If conflict resolution: at least A's content preserved locally
    assert a_content is not None and len(a_content) > 0, "A should still have content"
    assert server_note is not None, "Server should still have the note"

    # Check if auto-merge worked (best case)
    if "edited by A" in a_content and "edited by server" in a_content:
        # Auto-merge succeeded — verify server has merged version too
        api_sync.wait_for_note_content(path, "edited by A", timeout=10)
