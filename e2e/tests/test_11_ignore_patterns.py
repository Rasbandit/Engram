"""Test 11: Files matching ignore patterns should NOT sync.

The plugin's shouldIgnore uses prefix matching (trailing '/') and exact
matching, not glob patterns. Patterns are parsed from settings.ignorePatterns
(newline-separated) and cached — must call parseIgnorePatterns() after changing.
"""

import time

import pytest

from helpers.vault import write_note

ENGINE = "app.plugins.plugins['engram-sync'].syncEngine"


@pytest.mark.asyncio
async def test_ignore_patterns(vault_a, cdp_a, api_sync):
    """A file matching the ignore pattern should not be pushed to the server."""

    # Set ignore pattern and re-parse (prefix match: trailing '/')
    await cdp_a.evaluate(
        f"{ENGINE}.settings.ignorePatterns = 'Private/';"
        f"{ENGINE}.parseIgnorePatterns();"
        f"'set'"
    )

    # Create a file that matches the ignore pattern
    ignored_path = "Private/secret-diary.md"
    write_note(vault_a, ignored_path, "# Secret\nThis should NOT sync.")

    # Create a normal file that should sync (control group)
    normal_path = "E2E/IgnoreTestControl.md"
    write_note(vault_a, normal_path, "# Control\nThis SHOULD sync.")

    # Wait for the normal file to appear on server (proves push is working)
    api_sync.wait_for_note(normal_path, timeout=10)

    # The ignored file should NOT be on the server
    # Give extra time — if it were going to sync, it would have by now
    time.sleep(2)
    note = api_sync.get_note(ignored_path)
    assert note is None, "Ignored file should NOT appear on server"

    # Reset ignore patterns
    await cdp_a.evaluate(
        f"{ENGINE}.settings.ignorePatterns = '';"
        f"{ENGINE}.parseIgnorePatterns();"
        f"'reset'"
    )
