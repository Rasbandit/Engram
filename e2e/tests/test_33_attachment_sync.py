"""Test 33: Binary attachment syncs from vault A to vault B.

A creates a small PNG in the vault. The plugin detects it as a binary
extension, pushes via pushAttachment. B syncs and receives the file
with identical bytes.
"""

import time

import pytest

from helpers.vault import write_binary, wait_for_binary, wait_for_file_gone


# Minimal valid PNG: 1x1 red pixel
TINY_PNG = (
    b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01"
    b"\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90wS\xde\x00"
    b"\x00\x00\x0cIDATx\x9cc\xf8\x0f\x00\x00\x01\x01\x00"
    b"\x05\x18\xd8N\x00\x00\x00\x00IEND\xaeB`\x82"
)


@pytest.mark.asyncio
async def test_attachment_push_and_pull(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """A writes a PNG → server stores it → B pulls identical bytes."""
    att_path = "E2E/attachments/test33.png"

    # A creates attachment
    write_binary(vault_a, att_path, TINY_PNG)

    # Poll until plugin pushes attachment to server
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        resp = api_sync.get_attachment(att_path)
        if resp.status_code == 200:
            break
        time.sleep(0.5)
    assert resp.status_code == 200, f"Attachment should be on server, got {resp.status_code}"

    # B syncs
    await cdp_b.trigger_full_sync()

    # Verify B has the file with matching bytes
    b_data = wait_for_binary(vault_b, att_path, timeout=15)
    assert b_data == TINY_PNG, (
        f"B's attachment bytes should match. Got {len(b_data)} bytes, expected {len(TINY_PNG)}"
    )


@pytest.mark.asyncio
async def test_attachment_delete_propagation(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """Deleting an attachment on A removes it from server and B."""
    att_path = "E2E/attachments/test33del.png"

    # Setup: A creates, poll until server has it
    write_binary(vault_a, att_path, TINY_PNG)
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if api_sync.get_attachment(att_path).status_code == 200:
            break
        time.sleep(0.5)
    assert api_sync.get_attachment(att_path).status_code == 200, "Server should have attachment"

    # B syncs — retry if first pull doesn't fetch the attachment
    for attempt in range(3):
        await cdp_b.trigger_full_sync()
        if (vault_b / att_path).exists():
            break
        time.sleep(2)
    assert (vault_b / att_path).exists(), "B should have attachment before delete"

    # A deletes the attachment
    (vault_a / att_path).unlink()

    # Poll until server reflects deletion
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        resp = api_sync.get_attachment(att_path)
        if resp.status_code == 404:
            break
        time.sleep(0.5)
    assert resp.status_code == 404, f"Attachment should be gone from server, got {resp.status_code}"

    # B syncs — retry pull to propagate deletion
    for attempt in range(3):
        await cdp_b.trigger_full_sync()
        if not (vault_b / att_path).exists():
            break
        time.sleep(2)
    assert not (vault_b / att_path).exists(), "B should not have deleted attachment"
