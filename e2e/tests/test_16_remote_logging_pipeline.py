"""Test 16: Remote logging pipeline — logs ingest and retrieve correctly.

Exercises the full POST /logs → GET /logs pipeline: ingest batches with
various levels, verify retrieval, field presence, level filtering, and
multi-tenant isolation. The plugin's RemoteLogger flush mechanism is
covered by plugin unit tests (remote-log.test.ts).
"""

import pytest


@pytest.mark.asyncio
async def test_remote_logging_pipeline(api_sync):
    """Logs ingest via POST /logs and are retrievable via GET /logs."""

    marker = "e2e-test-16-marker"

    # Ingest a batch with info + warn levels
    status = api_sync.ingest_logs([
        {
            "ts": "2026-04-07T10:00:00Z",
            "level": "info",
            "category": "sync",
            "message": f"Test log entry 1 — {marker}",
            "plugin_version": "0.6.0",
            "platform": "desktop",
        },
        {
            "ts": "2026-04-07T10:00:01Z",
            "level": "warn",
            "category": "lifecycle",
            "message": f"Test warning — {marker}",
            "plugin_version": "0.6.0",
            "platform": "desktop",
        },
    ])
    assert status == 200, f"Log ingest should succeed, got {status}"

    # Retrieve logs
    logs_resp = api_sync.get_logs(limit=50)
    logs = logs_resp.get("logs", [])
    marker_logs = [l for l in logs if marker in l.get("message", "")]

    assert len(marker_logs) >= 2, (
        f"Expected at least 2 marker logs, got {len(marker_logs)}. "
        f"All logs: {[l.get('message', '')[:60] for l in logs]}"
    )

    # Verify log fields
    for log in marker_logs:
        assert "id" in log, "Log entry should have id"
        assert "ts" in log, "Log entry should have timestamp"
        assert log["level"] in ("info", "warn", "error"), f"Bad level: {log['level']}"
        assert log.get("category") in ("sync", "lifecycle"), f"Bad category: {log.get('category')}"

    # Verify level filter works
    warn_resp = api_sync.get_logs(level="warn", limit=50)
    warn_logs = [l for l in warn_resp.get("logs", []) if marker in l.get("message", "")]
    assert len(warn_logs) >= 1, "Should find at least 1 warn-level marker log"
    assert all(l["level"] == "warn" for l in warn_logs), "Level filter should only return warn"


@pytest.mark.asyncio
async def test_remote_logging_isolation(api_sync, api_iso):
    """User C cannot see sync-user's logs."""
    # Seed a log for sync-user
    api_sync.ingest_logs([{
        "ts": "2026-04-07T00:00:00Z",
        "level": "info",
        "category": "sync",
        "message": "isolation-check-16",
        "platform": "desktop",
    }])

    # sync-user sees their logs
    sync_logs = api_sync.get_logs(limit=50)
    assert any("isolation-check-16" in l.get("message", "") for l in sync_logs.get("logs", [])), \
        "sync-user should see their own log"

    # isolation-user should NOT see them
    iso_logs = api_iso.get_logs(limit=50)
    iso_messages = [l.get("message", "") for l in iso_logs.get("logs", [])]
    assert not any("isolation-check-16" in m for m in iso_messages), \
        "isolation-user must not see sync-user's logs"
