"""Test 17: Remote logging — error logs include stack traces.

Verifies that error-level logs with stack traces are stored and
retrievable, and that the stack field is preserved through the pipeline.
Info-level logs should not have a stack field.
"""

import pytest


@pytest.mark.asyncio
async def test_error_logs_with_stack(api_sync):
    """Error logs with stack traces are stored and retrievable."""

    marker = "e2e-test-17-stack"
    stack_trace = "Error: Something broke\n  at pushNote (sync.ts:100)\n  at fullSync (sync.ts:200)"

    status = api_sync.ingest_logs([{
        "ts": "2026-04-07T11:00:00Z",
        "level": "error",
        "category": "sync",
        "message": f"Push failed — {marker}",
        "stack": stack_trace,
        "plugin_version": "0.6.0",
        "platform": "desktop",
    }])
    assert status == 200, f"Log ingest should succeed, got {status}"

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
async def test_info_logs_no_stack(api_sync):
    """Info-level logs should not have a stack field (or it should be null)."""

    marker = "e2e-test-17-info"

    api_sync.ingest_logs([{
        "ts": "2026-04-07T11:01:00Z",
        "level": "info",
        "category": "sync",
        "message": f"Normal operation — {marker}",
        "platform": "desktop",
    }])

    resp = api_sync.get_logs(limit=50)
    logs = resp.get("logs", [])
    marker_logs = [l for l in logs if marker in l.get("message", "")]

    assert len(marker_logs) >= 1, "Should find info marker log"
    info_log = marker_logs[0]
    # stack should be absent or null for info logs
    assert not info_log.get("stack"), (
        f"Info log should not have stack, got: {info_log.get('stack')}"
    )
