"""Test 38: Notes with special characters in filenames sync correctly.

Tests unicode, spaces, parentheses, and emoji in file paths — all common
patterns in real Obsidian vaults.
"""

import pytest

from helpers.vault import wait_for_file, write_note


@pytest.mark.asyncio
async def test_spaces_in_path(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """File with spaces in name syncs A→B."""
    path = "E2E/My Notes (2026).md"

    write_note(vault_a, path, "# Spaced Path\nContent with spaces in filename.")
    api_sync.wait_for_note(path, timeout=10)

    await cdp_b.trigger_full_sync()
    b_content = wait_for_file(vault_b, path, timeout=15)
    assert "Spaced Path" in b_content


@pytest.mark.asyncio
async def test_unicode_in_path(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """File with unicode characters syncs A→B."""
    path = "E2E/Café Résumé.md"

    write_note(vault_a, path, "# Café Notes\nAccented characters in filename.")
    api_sync.wait_for_note(path, timeout=10)

    await cdp_b.trigger_full_sync()
    b_content = wait_for_file(vault_b, path, timeout=15)
    assert "Café Notes" in b_content


@pytest.mark.asyncio
async def test_emoji_in_path(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """File with emoji in name syncs A→B (common Obsidian pattern)."""
    path = "E2E/📝 Daily Log.md"

    write_note(vault_a, path, "# Daily Log\nEmoji filename test.")
    api_sync.wait_for_note(path, timeout=10)

    await cdp_b.trigger_full_sync()
    b_content = wait_for_file(vault_b, path, timeout=15)
    assert "Daily Log" in b_content


@pytest.mark.asyncio
async def test_special_chars_combined(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """File with mixed special characters syncs A→B."""
    path = "E2E/Project [v2.0] — Final (Draft).md"

    write_note(vault_a, path, "# Mixed Special Chars\nBrackets, em-dash, parens.")
    api_sync.wait_for_note(path, timeout=10)

    await cdp_b.trigger_full_sync()
    b_content = wait_for_file(vault_b, path, timeout=15)
    assert "Mixed Special Chars" in b_content
