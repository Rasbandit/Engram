"""Test 39: A and B push different notes simultaneously — both succeed.

Verifies no data loss when two devices sync different files concurrently.
Uses asyncio.gather to trigger parallel syncs.
"""

import asyncio

import pytest

from helpers.vault import write_note


@pytest.mark.asyncio
async def test_concurrent_push_different_notes(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """A and B create different notes simultaneously — server gets both."""
    path_a = "E2E/ConcurrentA39.md"
    path_b = "E2E/ConcurrentB39.md"

    # Both write to their own vaults
    write_note(vault_a, path_a, "# From A\nConcurrent push test.")
    write_note(vault_b, path_b, "# From B\nConcurrent push test.")

    # Trigger both syncs concurrently
    await asyncio.gather(
        cdp_a.trigger_full_sync(),
        cdp_b.trigger_full_sync(),
    )

    # Both notes should be on server
    api_sync.wait_for_note(path_a, timeout=15)
    api_sync.wait_for_note(path_b, timeout=15)

    note_a = api_sync.get_note(path_a)
    note_b = api_sync.get_note(path_b)
    assert "From A" in note_a["content"], "Server should have A's note"
    assert "From B" in note_b["content"], "Server should have B's note"

    # After another sync round, both vaults should have both notes
    await asyncio.gather(
        cdp_a.trigger_full_sync(),
        cdp_b.trigger_full_sync(),
    )

    assert (vault_a / path_b).exists() or api_sync.get_note(path_b) is not None, \
        "A should eventually get B's note"
    assert (vault_b / path_a).exists() or api_sync.get_note(path_a) is not None, \
        "B should eventually get A's note"
