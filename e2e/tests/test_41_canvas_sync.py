"""Test 41: Canvas files (.canvas) sync between A and B.

Canvas files are JSON text treated as TEXT_EXTENSIONS in the plugin.
They sync through the same pushNote path as markdown but with a
different extension. Verifies the full round-trip preserves JSON structure.
"""

import json

import pytest

from helpers.vault import wait_for_file, write_note


CANVAS_CONTENT = json.dumps({
    "nodes": [
        {"id": "node1", "type": "text", "text": "Hello canvas", "x": 0, "y": 0, "width": 200, "height": 100},
        {"id": "node2", "type": "text", "text": "Second node", "x": 300, "y": 0, "width": 200, "height": 100},
    ],
    "edges": [
        {"id": "edge1", "fromNode": "node1", "toNode": "node2"},
    ],
}, indent=2)


@pytest.mark.asyncio
async def test_canvas_sync(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """Canvas JSON file syncs A→B with structure preserved."""
    path = "E2E/TestCanvas41.canvas"

    # A creates a canvas file
    write_note(vault_a, path, CANVAS_CONTENT)

    # Wait for push — canvas uses pushNote (text extension)
    await cdp_a.trigger_full_sync()

    # Server should have it
    note = api_sync.wait_for_note(path, timeout=10)
    assert note is not None, "Canvas should be on server"

    # B syncs
    await cdp_b.trigger_full_sync()
    b_raw = wait_for_file(vault_b, path, timeout=15)

    # Verify JSON structure is preserved
    b_data = json.loads(b_raw)
    assert len(b_data["nodes"]) == 2, "Canvas should have 2 nodes"
    assert len(b_data["edges"]) == 1, "Canvas should have 1 edge"
    assert b_data["nodes"][0]["text"] == "Hello canvas"


@pytest.mark.asyncio
async def test_canvas_modify_sync(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """Modifying a canvas on A propagates changes to B."""
    path = "E2E/TestCanvasMod41.canvas"

    # Create base canvas
    write_note(vault_a, path, CANVAS_CONTENT)
    api_sync.wait_for_note(path, timeout=10)
    await cdp_b.trigger_full_sync()

    # Modify canvas — add a node
    modified = json.loads(CANVAS_CONTENT)
    modified["nodes"].append({
        "id": "node3", "type": "text", "text": "New node",
        "x": 0, "y": 200, "width": 200, "height": 100,
    })
    write_note(vault_a, path, json.dumps(modified, indent=2))

    api_sync.wait_for_note_content(path, "New node", timeout=10)

    # B syncs
    await cdp_b.trigger_full_sync()
    b_raw = wait_for_file(vault_b, path, timeout=15)
    b_data = json.loads(b_raw)
    assert len(b_data["nodes"]) == 3, "Modified canvas should have 3 nodes"
