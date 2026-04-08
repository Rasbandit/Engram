"""Test 37: Append-only sync — POST /notes/append adds content, B receives it.

Verifies that server-side append modifies the note and the appended
content propagates to B on next sync.
"""

import pytest

from helpers.vault import read_note, wait_for_content, write_note


@pytest.mark.asyncio
async def test_append_sync(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """Append via API grows the note, B receives cumulative content."""
    path = "E2E/AppendSync37.md"

    # A creates the base note
    write_note(vault_a, path, "# Append Test\nOriginal content.")
    api_sync.wait_for_note(path, timeout=10)

    # B syncs to get base
    await cdp_b.trigger_full_sync()
    assert (vault_b / path).exists(), "B should have base note"

    # Append via API
    status = api_sync.append_note(path, "\nAppended line 1.")
    assert status == 200, f"First append should succeed, got {status}"

    # Verify server has appended content
    api_sync.wait_for_note_content(path, "Appended line 1", timeout=10)

    # B syncs — should see appended content
    await cdp_b.trigger_full_sync()
    b_content = wait_for_content(vault_b, path, "Appended line 1", timeout=15)
    assert "Original content" in b_content, "Original content should be preserved"

    # Append again
    status = api_sync.append_note(path, "\nAppended line 2.")
    assert status == 200, f"Second append should succeed, got {status}"
    api_sync.wait_for_note_content(path, "Appended line 2", timeout=10)

    # B syncs again — cumulative
    await cdp_b.trigger_full_sync()
    b_content = wait_for_content(vault_b, path, "Appended line 2", timeout=15)
    assert "Appended line 1" in b_content, "First append should still be present"
    assert "Appended line 2" in b_content, "Second append should be present"
