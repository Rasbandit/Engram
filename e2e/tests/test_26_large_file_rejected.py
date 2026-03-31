"""Test 26: Files exceeding maxFileSizeMB are rejected gracefully.

The plugin checks binary file size against settings.maxFileSizeMB (default 5MB).
Oversized files should not be pushed, and the error should not block other syncs.

Note: The size check only applies to binary/attachment files (sync.ts:445),
not markdown notes. We test with a large binary file.
"""

import asyncio
import time

import pytest

from helpers.vault import write_note


@pytest.mark.asyncio
async def test_large_file_rejected(vault_a, cdp_a, api_sync):
    """Binary file > maxFileSizeMB is rejected, other files still sync."""
    large_path = "E2E/large-file.bin"
    normal_path = "E2E/NormalAfterLarge.md"

    # Write a 6MB binary file (exceeds 5MB default limit)
    large_file = vault_a / large_path
    large_file.parent.mkdir(parents=True, exist_ok=True)
    large_file.write_bytes(b"\x00" * (6 * 1024 * 1024))

    # Wait for push attempt
    await asyncio.sleep(3)

    # Large file should NOT be on server
    note = api_sync.get_note(large_path)
    assert note is None, "Large file should not be pushed to server"

    # Check that lastError mentions the size issue
    error = await cdp_a.get_last_error()
    assert "too large" in error.lower() or "File too large" in error, (
        f"Expected size error, got: {error}"
    )

    # Write a normal file — should sync fine (no cascading failure)
    write_note(vault_a, normal_path, "# Normal Note\nShould sync after large file rejection")
    api_sync.wait_for_note(normal_path, timeout=10)
