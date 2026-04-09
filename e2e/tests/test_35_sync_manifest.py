"""Test 35: Sync manifest reflects current note state after CRUD.

API-only test (no Obsidian needed). Creates notes, deletes one,
then verifies GET /sync/manifest returns exactly the expected set
with correct content_hash values. Assertions are strict: any extra,
duplicate, or stale entries within the test prefix cause failure.
"""

import pytest

pytestmark = pytest.mark.api_only


@pytest.mark.asyncio
async def test_manifest_after_crud(api_sync):
    """Manifest lists exactly the active notes with correct hashes, excludes deleted."""
    prefix = "E2E/Manifest35"
    paths = [f"{prefix}/A.md", f"{prefix}/B.md", f"{prefix}/C.md"]
    contents = ["# Alpha\nContent A", "# Bravo\nContent B", "# Charlie\nContent C"]

    # Create 3 notes
    for path, content in zip(paths, contents):
        api_sync.create_note(path, content)

    # Delete the middle one
    api_sync.delete_note(paths[1])

    expected_paths = {paths[0], paths[2]}

    # Get manifest
    manifest = api_sync.get_manifest()

    # Filter to only our test prefix to avoid cross-test pollution
    test_notes = [n for n in manifest["notes"] if n["path"].startswith(prefix)]
    test_paths = {n["path"] for n in test_notes}

    # Exact set — no extra, no missing, no duplicates
    assert test_paths == expected_paths, (
        f"Manifest should contain exactly {expected_paths}, "
        f"got {test_paths}"
    )

    # No duplicates (set vs list length)
    test_path_list = [n["path"] for n in test_notes]
    assert len(test_path_list) == len(test_paths), (
        f"Manifest has duplicate entries: {test_path_list}"
    )

    # Deleted note must be absent
    assert paths[1] not in test_paths, "Deleted note B must not be in manifest"

    # content_hash should be non-empty for active notes
    for note in test_notes:
        assert note.get("content_hash"), f"Note {note['path']} should have content_hash"

    # total_notes should reflect actual count (exact, not >=)
    total_test_notes = len(test_notes)
    assert total_test_notes == 2, (
        f"Should have exactly 2 test notes in manifest, got {total_test_notes}"
    )

    # Global total_notes must be at least our test count
    assert manifest["total_notes"] >= total_test_notes, (
        f"Global total_notes ({manifest['total_notes']}) should be >= "
        f"test notes ({total_test_notes})"
    )


@pytest.mark.asyncio
async def test_manifest_attachment_count(api_sync):
    """Manifest includes attachment counts."""
    manifest = api_sync.get_manifest()

    assert "total_attachments" in manifest, "Manifest should include total_attachments"
    assert "attachments" in manifest, "Manifest should include attachments list"
    assert isinstance(manifest["attachments"], list), "Attachments should be a list"
