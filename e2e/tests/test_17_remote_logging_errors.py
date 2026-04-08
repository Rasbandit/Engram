"""Test 17: Remote logging — error logs include stack traces.

Verifies that error-level logs with stack traces are stored and
retrievable, and that the stack field is preserved through the pipeline.
"""

import asyncio

import pytest


PLUGIN_PATH = "app.plugins.plugins['engram-sync']"


@pytest.mark.asyncio
async def test_error_logs_with_stack(cdp_a, api_sync):
    """Error logs with stack traces are stored and retrievable."""

    marker = "e2e-test-17-stack"
    stack_trace = "Error: Something broke\\n  at pushNote (sync.ts:100)\\n  at fullSync (sync.ts:200)"

    # Enable remote logging and inject error with stack
    await cdp_a.evaluate(f"""
        (async function() {{
            const plugin = {PLUGIN_PATH};
            plugin.rlog.setEnabled(true);
            plugin.rlog.error("sync", "Push failed — {marker}", "{stack_trace}");
            await plugin.rlog.flush();
            return 'done';
        }})()
    """, await_promise=True)

    await asyncio.sleep(1)

    # Retrieve error logs
    resp = api_sync.get_logs(level="error", limit=50)
    logs = resp.get("logs", [])
    marker_logs = [l for l in logs if marker in l.get("message", "")]

    assert len(marker_logs) >= 1, f"Expected error log with marker, got {len(marker_logs)}"

    error_log = marker_logs[0]
    assert error_log["level"] == "error"
    assert "stack" in error_log, "Error log should include stack field"
    assert "pushNote" in error_log["stack"], (
        f"Stack should contain function name, got: {error_log['stack'][:200]}"
    )


@pytest.mark.asyncio
async def test_info_logs_no_stack(cdp_a, api_sync):
    """Info-level logs should not have a stack field (or it should be null)."""

    marker = "e2e-test-17-info"

    await cdp_a.evaluate(f"""
        (async function() {{
            const plugin = {PLUGIN_PATH};
            plugin.rlog.setEnabled(true);
            plugin.rlog.info("sync", "Normal operation — {marker}");
            await plugin.rlog.flush();
            return 'done';
        }})()
    """, await_promise=True)

    await asyncio.sleep(1)

    resp = api_sync.get_logs(limit=50)
    logs = resp.get("logs", [])
    marker_logs = [l for l in logs if marker in l.get("message", "")]

    assert len(marker_logs) >= 1, "Should find info marker log"
    info_log = marker_logs[0]
    # stack should be absent or null for info logs
    assert not info_log.get("stack"), (
        f"Info log should not have stack, got: {info_log.get('stack')}"
    )
