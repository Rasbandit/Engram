"""Test 42: YAML frontmatter and tags are preserved through sync round-trip.

Obsidian vaults heavily use YAML frontmatter for metadata. This test
verifies that frontmatter survives push → server → pull without corruption.
"""

import pytest

from helpers.vault import read_note, wait_for_file, write_note


NOTE_WITH_FRONTMATTER = """\
---
title: Frontmatter Test
tags:
  - e2e-testing
  - sync
  - metadata
aliases:
  - FM Test
  - Test 42
date: 2026-04-07
custom_field: "value with: colons and 'quotes'"
---

# Frontmatter Test

This note has YAML frontmatter with various field types.

#inline-tag #another-tag
"""


@pytest.mark.asyncio
async def test_frontmatter_preserved(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """Frontmatter survives A→server→B round-trip without corruption."""
    path = "E2E/FrontmatterTest42.md"

    write_note(vault_a, path, NOTE_WITH_FRONTMATTER)
    api_sync.wait_for_note(path, timeout=10)

    # Verify server parsed tags
    server_note = api_sync.get_note(path)
    assert server_note is not None
    server_tags = server_note.get("tags", [])
    assert any("e2e-testing" in t for t in server_tags), f"Server should extract frontmatter tags, got: {server_tags}"

    # B syncs
    await cdp_b.trigger_full_sync()
    b_content = wait_for_file(vault_b, path, timeout=15)

    # Frontmatter delimiters preserved
    assert b_content.startswith("---"), "Frontmatter opening delimiter should be preserved"
    assert "title: Frontmatter Test" in b_content, "Title field should survive"
    assert "custom_field:" in b_content, "Custom fields should survive"
    assert '  - e2e-testing' in b_content, "Tag list should survive"
    assert "#inline-tag" in b_content, "Inline tags should survive"


@pytest.mark.asyncio
async def test_frontmatter_edit_sync(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """Editing frontmatter on A propagates changes to B."""
    path = "E2E/FrontmatterEdit42.md"

    # Create with initial frontmatter
    write_note(vault_a, path, "---\ntags:\n  - original\n---\n\n# FM Edit Test\n")
    api_sync.wait_for_note(path, timeout=10)
    await cdp_b.trigger_full_sync()

    # Edit frontmatter — add a tag
    write_note(vault_a, path, "---\ntags:\n  - original\n  - added-tag\n---\n\n# FM Edit Test\nUpdated.\n")
    api_sync.wait_for_note_content(path, "added-tag", timeout=10)

    # B syncs
    await cdp_b.trigger_full_sync()
    b_content = read_note(vault_b, path)
    assert "added-tag" in b_content, "New tag should appear in B's copy"
    assert "original" in b_content, "Original tag should still be in B's copy"
