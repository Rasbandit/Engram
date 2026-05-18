"""Test 55: Destructive confirm view in SyncPreviewModal.

Covers the typed-"delete" gate for the two destructive sync directions:
  - push-all-delete-remote ("Push all + delete remote")
  - pull-all-delete-local  ("Pull all + delete local")

Pre-PR-61 plugins lack the typed-confirm input — skip cleanly there.
"""

from __future__ import annotations

import pytest

from helpers.vault import write_note


SEED_DIR = "E2E/Preview55"


@pytest.fixture(autouse=True)
async def _require_gate(cdp_a):
    """Skip the whole module when the loaded plugin predates SyncPreviewModal."""
    if not await cdp_a.has_sync_gate():
        pytest.skip("Plugin lacks SyncPreviewModal — gate API not present")


async def _dismiss_via_escape(cdp) -> None:
    """Dispatch Escape on any open modal — resolves awaitChoice as 'cancel'."""
    await cdp.evaluate(
        "document.querySelectorAll('.modal-container .modal').forEach("
        "m => m.dispatchEvent(new KeyboardEvent('keydown', "
        "{key: 'Escape', bubbles: true})))"
    )


async def _seed_local_only(cdp, vault, path: str, content: str) -> None:
    """Create a divergent file that stays local (gate re-blocked after write)."""
    await cdp.pause_outgoing_sync()
    write_note(vault, path, content)
    await cdp.reset_sync_gate()


async def _restore_clean(cdp, vault, path: str) -> None:
    """Undo _seed_local_only: delete the seeded file, resume push, re-accept."""
    file_path = vault / path
    if file_path.exists():
        file_path.unlink()
    await cdp.resume_outgoing_sync()
    await cdp.accept_sync_gate()


@pytest.mark.parametrize(
    "label",
    [
        "Push all + delete remote",
        "Pull all + delete local",
    ],
)
@pytest.mark.asyncio
async def test_destructive_submit_locked_until_typed(vault_a, cdp_a, label):
    """Submit button stays disabled until "delete" is typed exactly.

    Flow:
      1. Open modal with a divergent file so options are rendered.
      2. Pick the destructive option — confirm view appears.
      3. Assert button disabled before any text.
      4. Type partial word "delet" — still disabled.
      5. Type full word "delete" — enabled.
      6. Escape to cancel — gate stays closed.
    """
    path = f"{SEED_DIR}/Lock.md"
    await _seed_local_only(cdp_a, vault_a, path, "# seed")
    try:
        await cdp_a.open_sync_preview_modal()
        await cdp_a.wait_for_sync_preview_modal()
        await cdp_a.pick_modal_option(label)

        assert not await cdp_a.destructive_submit_enabled(), (
            "Submit must be disabled before user types 'delete'"
        )

        await cdp_a.type_destructive_confirm("delet")
        assert not await cdp_a.destructive_submit_enabled(), (
            "Submit must remain disabled for partial input 'delet'"
        )

        await cdp_a.type_destructive_confirm("delete")
        assert await cdp_a.destructive_submit_enabled(), (
            "Submit must be enabled once 'delete' is typed exactly"
        )

        # Cancel via Escape — gate must stay closed (no sync dispatched).
        await _dismiss_via_escape(cdp_a)
        await cdp_a.wait_for_modal_closed()
        assert await cdp_a.is_sync_blocked(), (
            "Sync gate must remain blocked after cancel via Escape"
        )
    finally:
        await _restore_clean(cdp_a, vault_a, path)


@pytest.mark.asyncio
async def test_destructive_confirm_dispatches_choice(vault_a, cdp_a):
    """Full flow: pick destructive option → type "delete" → submit → choice recorded.

    Uses the choice spy (swallow=True) so no real sync runs.
    Asserts the dispatched choice is "push-all-delete-remote".
    """
    path = f"{SEED_DIR}/Dispatch.md"
    await _seed_local_only(cdp_a, vault_a, path, "# seed")
    await cdp_a.install_choice_spy(swallow=True)
    try:
        await cdp_a.open_sync_preview_modal()
        await cdp_a.wait_for_sync_preview_modal()

        await cdp_a.pick_modal_option("Push all + delete remote")
        await cdp_a.type_destructive_confirm("delete")
        await cdp_a.click_modal_confirm()

        await cdp_a.wait_for_modal_closed(timeout=10)

        recorded = await cdp_a.get_last_sync_choice()
        assert recorded == "push-all-delete-remote", (
            f"Expected runSyncFromChoice('push-all-delete-remote'), got {recorded!r}"
        )
    finally:
        await cdp_a.uninstall_choice_spy()
        await _restore_clean(cdp_a, vault_a, path)
