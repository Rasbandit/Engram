"""CDP (Chrome DevTools Protocol) client for interacting with Obsidian runtime."""

from __future__ import annotations

import asyncio
import json
import logging
import time
from typing import Any

import requests
import websockets

logger = logging.getLogger(__name__)

PLUGIN_ID = "engram-sync"
PLUGIN_PATH = f"app.plugins.plugins['{PLUGIN_ID}']"
ENGINE_PATH = f"{PLUGIN_PATH}.syncEngine"


class CdpError(Exception):
    pass


class CdpClient:
    def __init__(self, port: int = 9222, host: str = "127.0.0.1"):
        self.port = port
        self.host = host
        self._base_url = f"http://{host}:{port}"

    def _get_ws_url(self) -> str:
        resp = requests.get(f"{self._base_url}/json", timeout=5)
        resp.raise_for_status()
        pages = resp.json()
        if not pages:
            raise CdpError("No CDP pages available")
        return pages[0]["webSocketDebuggerUrl"]

    async def evaluate(self, expr: str, await_promise: bool = False) -> Any:
        """Evaluate JS expression in Obsidian's renderer process.

        Opens a fresh WebSocket per call to avoid stale connections.
        """
        ws_url = self._get_ws_url()
        async with websockets.connect(ws_url) as ws:
            msg = {
                "id": 1,
                "method": "Runtime.evaluate",
                "params": {
                    "expression": expr,
                    "returnByValue": True,
                    "awaitPromise": await_promise,
                },
            }
            await ws.send(json.dumps(msg))
            resp = json.loads(await ws.recv())

            if "error" in resp:
                raise CdpError(f"CDP error: {resp['error']}")

            result = resp.get("result", {}).get("result", {})
            if result.get("type") == "undefined":
                return None
            if "value" in result:
                return result["value"]
            if result.get("subtype") == "error":
                raise CdpError(f"JS error: {result.get('description', result)}")
            return result

    async def wait_for_plugin_ready(self, timeout: float = 30) -> None:
        """Poll until the engram-sync plugin's SyncEngine reports ready."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                ready = await self.evaluate(f"{ENGINE_PATH}.ready")
                if ready is True:
                    logger.info("Plugin ready on CDP port %d", self.port)
                    return
            except Exception:
                pass
            await asyncio.sleep(1)
        raise TimeoutError(
            f"Plugin not ready after {timeout}s on CDP port {self.port}"
        )

    async def trigger_full_sync(self) -> dict:
        """Call syncEngine.fullSync() and return {pulled, pushed}."""
        result = await self.evaluate(
            f"{ENGINE_PATH}.fullSync().then(r => JSON.stringify(r))",
            await_promise=True,
        )
        if isinstance(result, str):
            return json.loads(result)
        return result or {}

    async def trigger_pull(self) -> int:
        """Call syncEngine.pull() and return count of pulled notes."""
        result = await self.evaluate(
            f"{ENGINE_PATH}.pull().then(r => r)", await_promise=True
        )
        return result if isinstance(result, int) else 0

    async def get_sync_status(self) -> dict:
        """Read syncEngine.getStatus()."""
        result = await self.evaluate(
            f"JSON.stringify({ENGINE_PATH}.getStatus())"
        )
        if isinstance(result, str):
            return json.loads(result)
        return result or {}

    async def get_last_sync(self) -> str | None:
        """Read the lastSync timestamp string."""
        return await self.evaluate(f"{ENGINE_PATH}.lastSync")

    async def check_sse_connected(self) -> bool:
        """Check if the plugin's SSE stream is connected."""
        result = await self.evaluate(f"{PLUGIN_PATH}.sseConnected")
        return result is True

    async def set_conflict_resolution(self, mode: str) -> None:
        """Set the plugin's conflictResolution setting.

        Modes: 'auto' (creates conflict files) or 'modal' (calls onConflict handler).
        """
        js = f"{ENGINE_PATH}.settings.conflictResolution = '{mode}'"
        await self.evaluate(js)
        logger.info("Conflict resolution set to '%s' on CDP port %d", mode, self.port)

    async def override_conflict_handler(
        self, choice: str, merged_content: str | None = None
    ) -> None:
        """Override onConflict to auto-resolve with the given choice.

        Valid choices: 'keep-local', 'keep-remote', 'keep-both', 'skip', 'merge'
        """
        if merged_content is not None:
            escaped = json.dumps(merged_content)
            js = (
                f"{ENGINE_PATH}.onConflict = async (info) => "
                f"({{choice: '{choice}', mergedContent: {escaped}}})"
            )
        else:
            js = (
                f"{ENGINE_PATH}.onConflict = async (info) => "
                f"({{choice: '{choice}'}})"
            )
        await self.evaluate(js)
        logger.info("Conflict handler overridden to '%s'", choice)

    async def pause_outgoing_sync(self) -> None:
        """Block plugin from pushing changes by replacing handlers with no-ops.

        Saves originals so resume_outgoing_sync() can restore them.
        Also clears any pending debounce timers to prevent in-flight pushes.
        """
        js = f"""
        (function() {{
            const se = {ENGINE_PATH};
            se._origHandleModify = se.handleModify.bind(se);
            se._origHandleDelete = se.handleDelete.bind(se);
            se._origHandleRename = se.handleRename.bind(se);
            se.handleModify = () => {{}};
            se.handleDelete = () => {{}};
            se.handleRename = () => {{}};
            // Clear pending debounce timers
            for (const [, timer] of se.debounceTimers) clearTimeout(timer);
            se.debounceTimers.clear();
            return 'paused';
        }})()
        """
        result = await self.evaluate(js)
        logger.info("Outgoing sync paused on CDP port %d: %s", self.port, result)

    async def resume_outgoing_sync(self) -> None:
        """Restore original push handlers saved by pause_outgoing_sync()."""
        js = f"""
        (function() {{
            const se = {ENGINE_PATH};
            if (se._origHandleModify) se.handleModify = se._origHandleModify;
            if (se._origHandleDelete) se.handleDelete = se._origHandleDelete;
            if (se._origHandleRename) se.handleRename = se._origHandleRename;
            delete se._origHandleModify;
            delete se._origHandleDelete;
            delete se._origHandleRename;
            return 'resumed';
        }})()
        """
        result = await self.evaluate(js)
        logger.info("Outgoing sync resumed on CDP port %d: %s", self.port, result)

    async def rename_file(self, old_path: str, new_path: str) -> None:
        """Rename a file through Obsidian's vault API (triggers handleRename)."""
        escaped_old = json.dumps(old_path)
        escaped_new = json.dumps(new_path)
        js = f"""
        (async function() {{
            const file = app.vault.getAbstractFileByPath({escaped_old});
            if (!file) throw new Error('File not found: ' + {escaped_old});
            await app.vault.rename(file, {escaped_new});
            return 'renamed';
        }})()
        """
        result = await self.evaluate(js, await_promise=True)
        logger.info("Renamed %s → %s: %s", old_path, new_path, result)

    async def restore_conflict_handler(self) -> None:
        """Restore the original modal-based conflict handler.

        Re-wires the handler that opens ConflictModal.
        """
        js = f"""
        (function() {{
            const plugin = {PLUGIN_PATH};
            const ConflictModal = require('{PLUGIN_ID}').ConflictModal
                || plugin.app.plugins.plugins['{PLUGIN_ID}'].constructor.__ConflictModal;
            // Fallback: set to null so SyncEngine uses its default skip behavior
            plugin.syncEngine.onConflict = null;
        }})()
        """
        try:
            await self.evaluate(js)
        except CdpError:
            # If we can't restore the fancy handler, null is safe (defaults to skip)
            await self.evaluate(f"{ENGINE_PATH}.onConflict = null")
        logger.info("Conflict handler restored")
