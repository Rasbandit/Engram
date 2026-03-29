"""Test 18: Path sanitization — server strips illegal chars, plugin renames local file.

End-to-end flow:
1. A creates note with ? in filename
2. Server sanitizes path (strips ?)
3. A's plugin detects path mismatch, renames local file
4. B pulls → gets the clean filename
5. Server stores note under clean path
"""

import time

import pytest

from helpers.vault import read_note, write_note, wait_for_file


@pytest.mark.asyncio
async def test_illegal_chars_sanitized_on_push(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """Note with ? in filename → server sanitizes → A renames → B gets clean path."""
    dirty_path = "E2E/Why do I resist feeling good?.md"
    clean_path = "E2E/Why do I resist feeling good.md"
    content = "# Why do I resist feeling good?\nTest of path sanitization."

    # 1. A creates note with illegal char in filename
    write_note(vault_a, dirty_path, content)

    # 2. Wait for server to have the note under the CLEAN path
    note = api_sync.wait_for_note(clean_path, timeout=15)
    assert "path sanitization" in note["content"]

    # 3. Server should NOT have the dirty path
    dirty_note = api_sync.get_note(dirty_path)
    assert dirty_note is None, "Server should not store the unsanitized path"

    # 4. A's local file should have been renamed to clean path
    #    (plugin renames after seeing server response)
    time.sleep(2)  # give plugin time to rename
    a_content = read_note(vault_a, clean_path)
    assert "path sanitization" in a_content, "A's local file should be renamed to clean path"

    # 5. B pulls → should get the clean filename
    await cdp_b.trigger_full_sync()
    b_content = read_note(vault_b, clean_path)
    assert "path sanitization" in b_content, "B should receive note under clean path"


@pytest.mark.asyncio
async def test_clean_path_unchanged(vault_a, cdp_a, api_sync):
    """Note with no illegal chars → path unchanged, no rename."""
    path = "E2E/Normal Clean Path.md"
    content = "# Normal\nNo illegal characters here."

    write_note(vault_a, path, content)
    note = api_sync.wait_for_note(path, timeout=10)
    assert note["content"] is not None

    # Verify server path matches exactly
    assert note["path"] == path, f"Clean path should not change, got: {note['path']}"


@pytest.mark.asyncio
async def test_multiple_illegal_chars_stripped(vault_a, cdp_a, api_sync):
    """Multiple illegal chars in filename → all stripped."""
    dirty_path = 'E2E/What: A "Great" Day*.md'
    clean_path = "E2E/What A Great Day.md"
    content = "# What\nMultiple illegal characters."

    write_note(vault_a, dirty_path, content)
    note = api_sync.wait_for_note(clean_path, timeout=15)
    assert "Multiple illegal" in note["content"]

    # Dirty path should not exist on server
    assert api_sync.get_note(dirty_path) is None
