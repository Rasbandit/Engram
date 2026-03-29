"""Test 01: A creates file → pushes to server → B pulls → file in B's vault."""

import pytest

from helpers.vault import read_note, write_note


@pytest.mark.asyncio
async def test_a_creates_b_receives(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """True end-to-end: file written in vault A → server → vault B."""
    path = "E2E/PushPullTest.md"
    content = "# Push-Pull Test\nCreated in vault A, should appear in vault B."

    # A creates the note
    write_note(vault_a, path, content)

    # Poll server until A's plugin pushes it (replaces time.sleep(2))
    note = api_sync.wait_for_note(path, timeout=10)
    assert "Push-Pull Test" in note["content"]

    # B pulls explicitly
    await cdp_b.trigger_full_sync()

    # Verify file appeared in B's vault
    b_content = read_note(vault_b, path)
    assert "Push-Pull Test" in b_content, "B did not receive A's note after pull"
    assert "should appear in vault B" in b_content
