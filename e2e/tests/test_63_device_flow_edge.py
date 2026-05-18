"""Test 63: DeviceFlowModal expired-code state + close button.

User path covered:
  1. Open DeviceFlowModal by calling settingTab.startDeviceFlow().
  2. Capture the modal instance by patching Modal.prototype.open via
     require('obsidian').Modal (the same technique works because Obsidian
     loads as a CommonJS bundle in Electron — require('obsidian') is live).
  3. Force the expired-code state by calling renderExpired() directly on the
     captured instance.
  4. Assert the expired UI renders ("Code expired. Please try again.").
  5. Click the "Close" button — modal closes.

Why we do NOT stub window.fetch / requestUrl:
  DeviceFlowModal uses Obsidian's requestUrl() (not window.fetch) for all
  HTTP calls.  requestUrl is a native Obsidian bridge callable, not
  patchable via JS in the renderer process.  Stubbing window.fetch has no
  effect.

Why we call renderExpired() directly:
  The expired branch fires when elapsed >= 300 s OR on a 410 HTTP response.
  Both require either a 5-minute wait or a real server stub that intercepts
  requestUrl.  Calling the private method directly is idiomatic in this
  harness (see cdp.py patterns for conflict handler override, choice spy,
  etc.) and exercises the identical code path.

How we capture the modal instance:
  We temporarily patch Modal.prototype.open via require('obsidian').Modal
  to intercept the first open() call after we fire startDeviceFlow().
  The captured instance is stored on window.__e2e_dfInst.  We restore
  Modal.prototype.open immediately after capturing to avoid interfering
  with subsequent modals.

Selector corrections vs plan draft (device-flow-modal.ts):
  - Plan used .engram-device-flow-modal as the modal root class — NOT
    in source.  DeviceFlowModal never calls contentEl.addClass().
    We identify the open modal by h2 text "Link Obsidian to Engram".
  - Plan used .engram-expired — NOT in source.  renderExpired() adds no
    CSS class to contentEl.  We verify via paragraph text content.
  - Plan used .engram-cancel — NOT in source.  The expired-screen dismiss
    button text is "Close" (not "Cancel"; "Cancel" is on the code screen).
    We click by text match inside .engram-device-buttons.
  - openDeviceFlowModal is NOT a public method on the plugin.  We go
    through settingTab.startDeviceFlow() (fire-and-forget wrapper).

Cleanup (finally block):
  - Restore settingTab.startDeviceFlow.
  - Call inst.close() on the captured instance if still open.
  - Delete all window.__e2e_df* globals.
"""

from __future__ import annotations

import asyncio

import pytest


PLUGIN_ID = "engram-vault-sync"


# ---------------------------------------------------------------------------
# Skip gate
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
async def _require_device_flow(cdp_a):
    """Skip when the plugin build does not ship DeviceFlowModal.

    We check that settingTab.startDeviceFlow exists (introduced together
    with DeviceFlowModal).
    """
    has_method = await cdp_a.evaluate(
        f"typeof app.plugins.plugins['{PLUGIN_ID}']"
        f"?.settingTab?.startDeviceFlow === 'function'"
    )
    if not has_method:
        pytest.skip(
            "Plugin lacks settingTab.startDeviceFlow — DeviceFlowModal not present"
        )


# ---------------------------------------------------------------------------
# Test
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_device_flow_expired_and_close(cdp_a):
    """DeviceFlowModal shows expired UI; clicking Close dismisses it."""
    # ------------------------------------------------------------------
    # Step 1: Patch Modal.prototype.open to capture the next modal instance
    # opened, then fire settingTab.startDeviceFlow() (fire-and-forget).
    #
    # settingTab.startDeviceFlow() does:
    #   const modal = new DeviceFlowModal(this.app, this.plugin);
    #   const result = await modal.waitForResult();  // awaits until close()
    #   ...
    #
    # We replace startDeviceFlow with a wrapper that:
    #   a) Installs the Modal.prototype.open spy (captures 'this' on first call).
    #   b) Calls the original startDeviceFlow — but does NOT await it.
    #   c) Returns immediately so we regain control.
    # ------------------------------------------------------------------
    patched = await cdp_a.evaluate(
        f"""
        (() => {{
            const plugin = app.plugins.plugins['{PLUGIN_ID}'];
            const settingTab = plugin?.settingTab;
            if (!settingTab) return 'no-settings-tab';

            const origStart = settingTab.startDeviceFlow.bind(settingTab);
            settingTab.__origStartDeviceFlow = origStart;

            settingTab.startDeviceFlow = async function() {{
                // Patch Modal.prototype.open to intercept the first open() call.
                const obsidian = require('obsidian');
                const ModalProto = obsidian.Modal.prototype;
                const origOpen = ModalProto.open;
                let captured = false;
                ModalProto.open = function() {{
                    if (!captured) {{
                        captured = true;
                        window.__e2e_dfInst = this;
                        // Restore immediately — only intercept the first call.
                        ModalProto.open = origOpen;
                    }}
                    return origOpen.call(this);
                }};
                // Fire the real flow without awaiting (waitForResult blocks
                // until close() is called — we close it from Python side).
                window.__e2e_dfPromise = origStart();
            }};

            return 'patched';
        }})()
        """
    )
    assert patched == "patched", f"Failed to patch startDeviceFlow: {patched!r}"

    try:
        # Fire the overridden startDeviceFlow (non-blocking from Python's view).
        await cdp_a.evaluate(
            f"void app.plugins.plugins['{PLUGIN_ID}'].settingTab.startDeviceFlow()"
        )

        # ------------------------------------------------------------------
        # Wait for the modal h2 to appear in the DOM.
        # DeviceFlowModal.onOpen() renders <h2>Link Obsidian to Engram</h2>
        # synchronously before the async beginDeviceFlow() runs.
        # ------------------------------------------------------------------
        modal_present = False
        for _ in range(100):  # 10 s — opening a modal is fast on warm CI
            present = await cdp_a.evaluate(
                """
                Boolean(Array.from(
                    document.querySelectorAll('.modal-container .modal-content h2')
                ).find(h => h.textContent.includes('Link Obsidian to Engram')))
                """
            )
            if present:
                modal_present = True
                break
            await asyncio.sleep(0.1)
        assert modal_present, (
            "DeviceFlowModal h2 did not appear within 10 s after startDeviceFlow() "
            "fired. The Modal.prototype.open patch was confirmed installed above; "
            "if the h2 is missing, either startDeviceFlow failed at the network "
            "request (check Obsidian devtools) or DeviceFlowModal.onOpen no "
            "longer renders the h2."
        )

        # Let beginDeviceFlow() settle (will fail fast if /auth/device returns
        # an error, leaving the 'Failed to start device flow' paragraph; or it
        # may succeed and render the code screen — either is fine for our test).
        await asyncio.sleep(0.3)

        # ------------------------------------------------------------------
        # Step 2: Force expired state via renderExpired() on the captured inst.
        # renderExpired() is private in TypeScript but is a plain JS property
        # at runtime.
        # ------------------------------------------------------------------
        rendered = await cdp_a.evaluate(
            """
            (() => {
                const inst = window.__e2e_dfInst;
                if (!inst) return 'no-instance';
                if (typeof inst.renderExpired !== 'function') return 'no-method';
                inst.renderExpired();
                return 'ok';
            })()
            """
        )
        assert rendered != "no-instance", (
            "DeviceFlowModal instance was not captured by the "
            "Modal.prototype.open spy. The h2 rendered above, so a modal "
            "did open — check that the spy fires for the FIRST open() call "
            "and that no earlier modal stole the spy slot."
        )
        assert rendered != "no-method", (
            "renderExpired() is missing on the captured DeviceFlowModal "
            "instance. Source defines it as a private method; if the build "
            "renamed or minified it, update the assertion to match the new "
            "method name."
        )
        assert rendered == "ok", f"renderExpired() returned unexpected: {rendered!r}"

        # ------------------------------------------------------------------
        # Step 3: Assert the expired UI is rendered.
        # renderExpired() empties contentEl and renders:
        #   <h2>Link Obsidian to Engram</h2>
        #   <p>Code expired. Please try again.</p>
        #   <div class="engram-device-buttons">
        #     <button class="mod-cta">Try again</button>
        #     <button>Close</button>
        #   </div>
        # ------------------------------------------------------------------
        content_text = await cdp_a.evaluate(
            """
            (() => {
                for (const c of document.querySelectorAll(
                    '.modal-container .modal-content'
                )) {
                    if (c.querySelector('h2')?.textContent.includes(
                        'Link Obsidian to Engram'
                    )) return c.textContent;
                }
                return '';
            })()
            """
        )
        assert "Code expired" in content_text, (
            f"Expected 'Code expired' text after renderExpired(). "
            f"Modal content: {content_text!r}"
        )

        # ------------------------------------------------------------------
        # Step 4: Click "Close" and assert modal closes.
        # The expired screen renders buttons inside .engram-device-buttons:
        #   "Try again" (mod-cta) and "Close" (plain button).
        # ------------------------------------------------------------------
        clicked = await cdp_a.evaluate(
            """
            (() => {
                for (const c of document.querySelectorAll(
                    '.modal-container .modal-content'
                )) {
                    if (!c.querySelector('h2')?.textContent.includes(
                        'Link Obsidian to Engram'
                    )) continue;
                    const btns = c.querySelectorAll('.engram-device-buttons button');
                    const closeBtn = Array.from(btns).find(
                        b => b.textContent.trim() === 'Close'
                    );
                    if (!closeBtn) return 'no-close-btn';
                    closeBtn.click();
                    return 'clicked';
                }
                return 'modal-not-found';
            })()
            """
        )
        assert clicked == "clicked", (
            f"'Close' button not found in expired DeviceFlowModal. "
            f"DOM result: {clicked!r}"
        )

        # Wait for the modal to disappear from the DOM.
        for _ in range(50):
            still_open = await cdp_a.evaluate(
                """
                Boolean(Array.from(
                    document.querySelectorAll('.modal-container .modal-content h2')
                ).find(h => h.textContent.includes('Link Obsidian to Engram')))
                """
            )
            if not still_open:
                break
            await asyncio.sleep(0.1)
        else:
            pytest.fail(
                "DeviceFlowModal did not close within 5 s after clicking 'Close'"
            )

    finally:
        # ------------------------------------------------------------------
        # Restore startDeviceFlow, close any lingering modal, clean up globals.
        # ------------------------------------------------------------------
        await cdp_a.evaluate(
            f"""
            (() => {{
                const plugin = app.plugins.plugins['{PLUGIN_ID}'];
                const settingTab = plugin?.settingTab;
                if (settingTab?.__origStartDeviceFlow) {{
                    settingTab.startDeviceFlow = settingTab.__origStartDeviceFlow;
                    delete settingTab.__origStartDeviceFlow;
                }}
                const inst = window.__e2e_dfInst;
                if (inst && typeof inst.close === 'function') {{
                    try {{ inst.close(); }} catch (_) {{}}
                }}
                delete window.__e2e_dfInst;
                delete window.__e2e_dfPromise;
            }})()
            """
        )
        # Allow close() handlers and the waitForResult() promise to settle.
        await asyncio.sleep(0.2)
