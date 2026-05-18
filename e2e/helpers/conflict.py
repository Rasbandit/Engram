"""Shared conflict test setup — used by test_06, test_13, test_14, test_21, test_22,
test_54.

Extracts two patterns:

1. ``setup_conflict`` — the original 5-step pattern used by test_06/13/14/21/22:
   A creates base note, B syncs to get it, A edits, B pauses and edits locally.
   Requires api_sync fixture.

2. ``setup_conflict_for_a`` / ``restore_after_conflict`` — the simpler 2-party
   pattern for test_54 (ConflictModal UI):
   B writes remote content and syncs to server, then A writes local content and
   triggers pull so that Vault A detects divergence and opens ConflictModal
   (requires ``conflictResolution == 'modal'`` already set on A before call).
   Does NOT require api_sync.
"""

from __future__ import annotations

import asyncio
import time

from helpers.vault import write_note


async def setup_conflict(
    path: str,
    vault_a,
    vault_b,
    cdp_b,
    api_sync,
    *,
    a_edit: str = "Edited by A",
    b_edit: str = "Edited by B",
    base_content: str = "Base content",
):
    """Create a conflict: A and B both edit the same note.

    After this function returns:
    - Server has A's version
    - B has B's version locally (outgoing sync paused)
    - B's syncedHash records the original base, so pull will detect conflict

    Raises AssertionError if pause_outgoing_sync failed to prevent B's push.
    """
    # 1. A creates the base note
    write_note(vault_a, path, f"# Conflict Test\n{base_content}")
    api_sync.wait_for_note(path, timeout=10)

    # 2. B pulls to establish synced state (records syncedHash)
    await cdp_b.trigger_full_sync()
    assert (vault_b / path).exists(), "B should have the base note after pull"

    # 3. A edits → push to server
    write_note(vault_a, path, f"# Conflict Test\n{a_edit}")
    api_sync.wait_for_note_content(path, a_edit, timeout=10)

    # 4. Pause B's outgoing sync so B's edit stays local-only
    await cdp_b.pause_outgoing_sync()

    # 5. B edits locally
    write_note(vault_b, path, f"# Conflict Test\n{b_edit}")

    # 6. Verify pause is working — B's edit must NOT overwrite A's on server.
    #    Plugin debounce is 300ms; 1s = 3x margin for push to have fired if unpaused.
    time.sleep(1)
    server_note = api_sync.get_note(path)
    assert server_note is not None, "Server note disappeared during conflict setup"
    assert b_edit not in server_note.get("content", ""), (
        f"pause_outgoing_sync FAILED: B's edit '{b_edit}' reached the server. "
        f"All conflict tests using this helper are invalid."
    )


# ---------------------------------------------------------------------------
# Two-party conflict helpers for test_54 (ConflictModal UI)
# ---------------------------------------------------------------------------


async def setup_conflict_for_a(
    vault_a,
    vault_b,
    cdp_a,
    cdp_b,
    path: str,
    *,
    local: str,
    remote: str,
) -> None:
    """Seed a conflict that opens ConflictModal on Vault A.

    Steps:
    1. Write ``remote`` content to vault B and trigger a full sync so the server
       stores B's version.
    2. Pause outgoing sync on A so A's local write cannot auto-push and override.
    3. Write ``local`` content to vault A.
    4. Resume outgoing sync on A and trigger a pull — the engine detects
       divergence (server has B's version; A has a local edit it hasn't pushed)
       and, because ``conflictResolution`` is already ``'modal'``, opens the
       ConflictModal.

    The caller MUST set ``conflictResolution = 'modal'`` on A before calling
    (e.g. via the ``_set_modal_mode`` autouse fixture in test_54).

    Waits up to 10 s for the modal DOM node to appear.  Raises TimeoutError if
    the modal never mounts.
    """
    # 1. B writes remote content and syncs to server.
    write_note(vault_b, path, remote)
    await cdp_b.trigger_full_sync()

    # 2. Pause A's outgoing sync so the local write stays off-server.
    await cdp_a.pause_outgoing_sync()

    # 3. Write local content to vault A.
    write_note(vault_a, path, local)

    # 4. Resume A's outgoing sync, then pull so divergence is detected.
    await cdp_a.resume_outgoing_sync()
    await cdp_a.trigger_pull()

    # Wait for ConflictModal to mount (async — may arrive via SSE or pull response).
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        present = await cdp_a.evaluate(
            "Boolean(document.querySelector('.engram-conflict-modal'))"
        )
        if present:
            return
        await asyncio.sleep(0.2)
    raise TimeoutError(
        f"ConflictModal never opened for path '{path}' within 10 s"
    )


async def restore_after_conflict(
    vault_a,
    vault_b,
    cdp_a,
    cdp_b,
    path: str,
) -> None:
    """Remove the seeded file from both vaults and reconcile with the server.

    Deletes the file from both local vaults then triggers a full sync on each
    so the server also removes its copy.  Safe to call even if the file is
    already absent (``missing_ok=True``).
    """
    (vault_a / path).unlink(missing_ok=True)
    (vault_b / path).unlink(missing_ok=True)
    await cdp_a.trigger_full_sync()
    await cdp_b.trigger_full_sync()
