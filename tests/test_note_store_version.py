"""Unit tests for note_store version counter (optimistic concurrency control).

Tests cover:
- Version increments on upsert (insert and update)
- 409 conflict when expected_version doesn't match
- NULL version = unconditional update (backwards compat)
- Version field present in get_note, get_changes_since, get_manifest
"""

from __future__ import annotations

import sys
from datetime import datetime, timezone
from unittest.mock import MagicMock, patch, call

# Stub DB dependencies before importing note_store
sys.modules.setdefault("psycopg", MagicMock())
sys.modules.setdefault("psycopg.errors", MagicMock())
pool_mock = MagicMock()
sys.modules.setdefault("pool", pool_mock)

import note_store


def _make_conn_mock(fetchone_return=None, fetchall_return=None):
    """Create a mock connection context manager with execute().fetchone/fetchall."""
    conn = MagicMock()
    cursor = MagicMock()
    cursor.fetchone.return_value = fetchone_return
    cursor.fetchall.return_value = fetchall_return or []
    conn.execute.return_value = cursor
    pool = MagicMock()
    pool.connection.return_value.__enter__ = MagicMock(return_value=conn)
    pool.connection.return_value.__exit__ = MagicMock(return_value=False)
    return pool, conn


class TestUpsertNoteVersion:
    """Tests for version counter in upsert_note."""

    def test_upsert_returns_version(self):
        """upsert_note should return version from RETURNING clause."""
        now = datetime.now(timezone.utc)
        pool, conn = _make_conn_mock(
            fetchone_return=(1, "user1", "test.md", "Test", "", [], 1.0, now, now, 1)
        )
        with patch.object(note_store, "get_pool", return_value=pool):
            result = note_store.upsert_note("user1", "test.md", "# Test", 1.0)
        assert "version" in result
        assert result["version"] == 1

    def test_upsert_passes_expected_version_in_sql(self):
        """When expected_version is provided, it should appear in the SQL params."""
        now = datetime.now(timezone.utc)
        pool, conn = _make_conn_mock(
            fetchone_return=(1, "user1", "test.md", "Test", "", [], 1.0, now, now, 2)
        )
        with patch.object(note_store, "get_pool", return_value=pool):
            result = note_store.upsert_note("user1", "test.md", "# Test", 1.0, expected_version=1)
        # Verify the SQL was called with expected_version in params
        sql_call = conn.execute.call_args
        params = sql_call[0][1]  # Second positional arg = params tuple
        # expected_version should appear in the params
        assert 1 in params

    def test_upsert_null_version_unconditional(self):
        """When expected_version is None, update should be unconditional (backwards compat)."""
        now = datetime.now(timezone.utc)
        pool, conn = _make_conn_mock(
            fetchone_return=(1, "user1", "test.md", "Test", "", [], 1.0, now, now, 5)
        )
        with patch.object(note_store, "get_pool", return_value=pool):
            result = note_store.upsert_note("user1", "test.md", "# Test", 1.0, expected_version=None)
        assert result["version"] == 5

    def test_upsert_conflict_returns_conflict_dict(self):
        """When expected_version mismatches (RETURNING empty), return conflict info."""
        now = datetime.now(timezone.utc)
        pool, conn = _make_conn_mock(fetchone_return=None)  # No row returned = version mismatch

        # Mock the re-fetch of current server note
        refetch_cursor = MagicMock()
        refetch_cursor.fetchone.return_value = (
            1, "test.md", "Title", "# Server content", "", [], 1.0, now, now, 3
        )
        # First execute returns None (conflict), second returns server note
        conn.execute.side_effect = [
            MagicMock(fetchone=MagicMock(return_value=None)),
            refetch_cursor,
        ]

        with patch.object(note_store, "get_pool", return_value=pool):
            result = note_store.upsert_note("user1", "test.md", "# Test", 1.0, expected_version=1)

        assert result["conflict"] is True
        assert "server_note" in result
        assert result["server_note"]["version"] == 3
        assert result["server_note"]["content"] == "# Server content"


class TestGetNoteVersion:
    """Tests for version field in get_note."""

    def test_get_note_includes_version(self):
        """get_note should include version in returned dict."""
        now = datetime.now(timezone.utc)
        pool, conn = _make_conn_mock(
            fetchone_return=(1, "test.md", "Title", "# Content", "", [], 1.0, now, now, 3)
        )
        with patch.object(note_store, "get_pool", return_value=pool):
            result = note_store.get_note("user1", "test.md")
        assert result is not None
        assert result["version"] == 3


class TestGetChangesSinceVersion:
    """Tests for version field in get_changes_since."""

    def test_changes_include_version(self):
        """get_changes_since should include version in each change dict."""
        now = datetime.now(timezone.utc)
        pool, conn = _make_conn_mock(
            fetchall_return=[
                ("note1.md", "Title1", "# Content1", "", [], 1.0, now, None, 2),
                ("note2.md", "Title2", "# Content2", "Folder", ["tag"], 2.0, now, None, 5),
            ]
        )
        with patch.object(note_store, "get_pool", return_value=pool):
            result = note_store.get_changes_since("user1", now)
        assert len(result) == 2
        assert result[0]["version"] == 2
        assert result[1]["version"] == 5


class TestGetManifestVersion:
    """Tests for version field in get_manifest."""

    def test_manifest_includes_version(self):
        """get_manifest should include version in each entry."""
        pool, conn = _make_conn_mock(
            fetchall_return=[
                ("note1.md", "abc123", 1),
                ("note2.md", "def456", 4),
            ]
        )
        with patch.object(note_store, "get_pool", return_value=pool):
            result = note_store.get_manifest("user1")
        assert len(result) == 2
        assert result[0]["version"] == 1
        assert result[1]["version"] == 4
