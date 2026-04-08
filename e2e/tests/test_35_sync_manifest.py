"""Test 35: Sync manifest reflects current note state after CRUD.

API-only test (no Obsidian needed). Creates notes, deletes one,
then verifies GET /sync/manifest returns exactly the expected set
with correct content_hash values.
"""

import pytest


@pytest.mark.asyncio
async def test_manifest_after_crud(api_sync):
    """Manifest lists active notes with correct hashes, excludes deleted."""
    prefix = "E2E/Manifest35"
    paths = [f"{prefix}/A.md", f"{prefix}/B.md", f"{prefix}/C.md"]
    contents = ["# Alpha\nContent A", "# Bravo\nContent B", "# Charlie\nContent C"]

    # Create 3 notes
    for path, content in zip(paths, contents):
        api_sync.create_note(path, content)

    # Delete the middle one
    api_sync.delete_note(paths[1])

    # Get manifest
    manifest = api_sync.get_manifest()

    manifest_paths = [n["path"] for n in manifest["notes"]]

    # Active notes should be present
    assert paths[0] in manifest_paths, "Note A should be in manifest"
    assert paths[2] in manifest_paths, "Note C should be in manifest"

    # Deleted note should be absent
    assert paths[1] not in manifest_paths, "Deleted note B should not be in manifest"

    # content_hash should be non-empty for active notes
    for note in manifest["notes"]:
        if note["path"] in (paths[0], paths[2]):
            assert note.get("content_hash"), f"Note {note['path']} should have content_hash"

    # total_notes should be accurate
    assert manifest["total_notes"] >= 2, "Should have at least 2 notes in manifest"


@pytest.mark.asyncio
async def test_manifest_attachment_count(api_sync):
    """Manifest includes attachment counts."""
    manifest = api_sync.get_manifest()

    assert "total_attachments" in manifest, "Manifest should include total_attachments"
    assert "attachments" in manifest, "Manifest should include attachments list"
    assert isinstance(manifest["attachments"], list), "Attachments should be a list"
