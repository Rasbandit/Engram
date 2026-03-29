"""Unit tests for db.py API key validation — local cache behavior, TTL, throttling."""

from __future__ import annotations

import hashlib
import sys
import time
from datetime import datetime, timezone
from unittest.mock import MagicMock, patch

import pytest

# Stub heavy dependencies
sys.modules.setdefault("psycopg", MagicMock())
sys.modules.setdefault("psycopg.errors", MagicMock())
sys.modules.setdefault("pool", MagicMock())
sys.modules.setdefault("redis_client", MagicMock(is_enabled=MagicMock(return_value=False)))

import db


def _hash(raw_key: str) -> str:
    return hashlib.sha256(raw_key.encode()).hexdigest()


def _make_pool_mock(fetchone_return=None):
    """Create a properly chained pool mock that returns the given fetchone result."""
    mock_cursor = MagicMock()
    mock_cursor.fetchone.return_value = fetchone_return

    mock_conn = MagicMock()
    mock_conn.__enter__ = MagicMock(return_value=mock_conn)
    mock_conn.__exit__ = MagicMock(return_value=False)
    mock_conn.execute.return_value = mock_cursor

    mock_pool = MagicMock()
    mock_pool.connection.return_value = mock_conn
    return mock_pool, mock_conn


@pytest.fixture(autouse=True)
def _clear_cache():
    """Clear the module-level caches between tests."""
    db._key_cache.clear()
    db._last_used_updates.clear()
    yield
    db._key_cache.clear()
    db._last_used_updates.clear()


# ---------------------------------------------------------------------------
# validate_api_key basics
# ---------------------------------------------------------------------------


class TestValidateApiKey:
    def test_valid_key_returns_user_dict(self):
        # row: (key_id, user_id, email, display_name)
        pool, _ = _make_pool_mock(fetchone_return=(99, 1, "u@test.com", "U"))
        with patch("db.get_pool", return_value=pool):
            result = db._validate_api_key_local(_hash("engram_abc123"))
        assert result == {"id": 1, "email": "u@test.com", "display_name": "U"}

    def test_invalid_key_returns_none(self):
        pool, _ = _make_pool_mock(fetchone_return=None)
        with patch("db.get_pool", return_value=pool):
            result = db._validate_api_key_local(_hash("engram_invalid"))
        assert result is None

    def test_hashes_key_with_sha256(self):
        """validate_api_key should SHA256-hash the raw key before lookup."""
        raw = "engram_testkey"
        expected_hash = _hash(raw)
        with patch.object(db, "_validate_api_key_local", return_value=None) as mock_local:
            with patch.object(db, "redis_client", MagicMock(is_enabled=MagicMock(return_value=False))):
                db.validate_api_key(raw)
        mock_local.assert_called_once_with(expected_hash)


# ---------------------------------------------------------------------------
# Local cache behavior
# ---------------------------------------------------------------------------


class TestLocalCache:
    def test_cache_hit_skips_db(self):
        key_hash = _hash("engram_cached")
        user = {"id": 1, "email": "c@test.com", "display_name": "C"}
        db._key_cache[key_hash] = (user, time.monotonic())
        db._last_used_updates[key_hash] = time.monotonic()

        pool, conn = _make_pool_mock()
        with patch("db.get_pool", return_value=pool):
            result = db._validate_api_key_local(key_hash)
        assert result == user
        # Pool should not have been called (cache hit, throttle active)
        pool.connection.assert_not_called()

    def test_expired_cache_queries_db(self):
        key_hash = _hash("engram_expired")
        user = {"id": 2, "email": "old@test.com", "display_name": "Old"}
        # Cache entry from 6 minutes ago (beyond 5-minute TTL)
        db._key_cache[key_hash] = (user, time.monotonic() - 360)

        pool, _ = _make_pool_mock(fetchone_return=(99, 2, "old@test.com", "Old"))
        with patch("db.get_pool", return_value=pool):
            result = db._validate_api_key_local(key_hash)
        assert result is not None
        assert result["id"] == 2

    def test_cache_stores_result_after_db_hit(self):
        key_hash = _hash("engram_new")
        pool, _ = _make_pool_mock(fetchone_return=(99, 3, "new@test.com", "New"))
        with patch("db.get_pool", return_value=pool):
            db._validate_api_key_local(key_hash)
        assert key_hash in db._key_cache
        cached_user, _ = db._key_cache[key_hash]
        assert cached_user["id"] == 3


# ---------------------------------------------------------------------------
# last_used throttling
# ---------------------------------------------------------------------------


class TestLastUsedThrottling:
    def test_first_access_updates_last_used(self):
        """First validation should update last_used in DB."""
        key_hash = _hash("engram_first")
        pool, _ = _make_pool_mock(fetchone_return=(99, 1, "f@test.com", "F"))
        with patch("db.get_pool", return_value=pool):
            db._validate_api_key_local(key_hash)
        assert key_hash in db._last_used_updates

    def test_rapid_access_throttles_last_used_update(self):
        """Second access within 60s should NOT update last_used again."""
        key_hash = _hash("engram_throttle")
        user = {"id": 1, "email": "t@test.com", "display_name": "T"}
        now = time.monotonic()
        db._key_cache[key_hash] = (user, now)
        db._last_used_updates[key_hash] = now  # just updated

        pool, conn = _make_pool_mock()
        with patch("db.get_pool", return_value=pool):
            db._validate_api_key_local(key_hash)
        # Pool should not have been used for UPDATE (throttled)
        pool.connection.assert_not_called()

    def test_stale_throttle_allows_update(self):
        """Access after 60s should update last_used again."""
        key_hash = _hash("engram_stale")
        user = {"id": 1, "email": "s@test.com", "display_name": "S"}
        now = time.monotonic()
        db._key_cache[key_hash] = (user, now)
        db._last_used_updates[key_hash] = now - 61  # 61s ago — past interval

        pool, conn = _make_pool_mock()
        with patch("db.get_pool", return_value=pool):
            db._validate_api_key_local(key_hash)
        # Should have opened a connection for the UPDATE
        pool.connection.assert_called()


# ---------------------------------------------------------------------------
# delete_api_key cache invalidation
# ---------------------------------------------------------------------------


class TestDeleteApiKeyCacheInvalidation:
    def test_delete_clears_local_cache(self):
        key_hash = "fakehash123"
        db._key_cache[key_hash] = ({"id": 1}, time.monotonic())
        db._last_used_updates[key_hash] = time.monotonic()

        # First execute: SELECT key_hash → returns the hash
        # Second execute: DELETE
        mock_conn = MagicMock()
        mock_conn.__enter__ = MagicMock(return_value=mock_conn)
        mock_conn.__exit__ = MagicMock(return_value=False)
        select_cursor = MagicMock()
        select_cursor.fetchone.return_value = (key_hash,)
        mock_conn.execute.return_value = select_cursor

        mock_pool = MagicMock()
        mock_pool.connection.return_value = mock_conn

        with patch("db.get_pool", return_value=mock_pool):
            with patch("db.redis_client", MagicMock(is_enabled=MagicMock(return_value=False))):
                db.delete_api_key(user_id=1, key_id=99)

        assert key_hash not in db._key_cache
        assert key_hash not in db._last_used_updates

    def test_delete_nonexistent_returns_false(self):
        pool, _ = _make_pool_mock(fetchone_return=None)
        with patch("db.get_pool", return_value=pool):
            with patch("db.redis_client", MagicMock(is_enabled=MagicMock(return_value=False))):
                result = db.delete_api_key(user_id=1, key_id=999)
        assert result is False


# ---------------------------------------------------------------------------
# create_api_key
# ---------------------------------------------------------------------------


class TestCreateApiKey:
    def test_returns_key_with_engram_prefix(self):
        pool, _ = _make_pool_mock()
        with patch("db.get_pool", return_value=pool):
            raw_key = db.create_api_key(user_id=1, name="test")
        assert raw_key.startswith("engram_")

    def test_key_is_unique_each_call(self):
        pool, _ = _make_pool_mock()
        with patch("db.get_pool", return_value=pool):
            keys = {db.create_api_key(user_id=1, name="test") for _ in range(10)}
        assert len(keys) == 10

    def test_stores_hash_not_raw_key(self):
        pool, conn = _make_pool_mock()
        with patch("db.get_pool", return_value=pool):
            raw_key = db.create_api_key(user_id=1, name="test")
        # Check the INSERT call args
        insert_call = conn.execute.call_args
        args_tuple = insert_call[0][1]  # (user_id, key_hash, name)
        stored_hash = args_tuple[1]
        expected_hash = hashlib.sha256(raw_key.encode()).hexdigest()
        assert stored_hash == expected_hash
