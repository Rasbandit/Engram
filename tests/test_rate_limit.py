"""Unit tests for rate_limit.py — sliding window, 429 enforcement, unlimited mode, Redis backend."""

from __future__ import annotations

import sys
import time
from unittest.mock import MagicMock, patch

import pytest

# Stub dependencies
sys.modules.setdefault("psycopg", MagicMock())
sys.modules.setdefault("psycopg.errors", MagicMock())
sys.modules.setdefault("pool", MagicMock())
sys.modules.setdefault("redis_client", MagicMock(is_enabled=MagicMock(return_value=False)))

from fastapi import HTTPException

from rate_limit import RateLimiter


# ---------------------------------------------------------------------------
# Unlimited mode (max_requests <= 0)
# ---------------------------------------------------------------------------


class TestUnlimitedMode:
    @pytest.mark.parametrize("max_requests", [0, -1], ids=["zero", "negative"])
    def test_unlimited_allows_all_requests(self, max_requests):
        limiter = RateLimiter(max_requests=max_requests)
        for _ in range(100):
            limiter.check("user-1")


# ---------------------------------------------------------------------------
# Basic enforcement (local)
# ---------------------------------------------------------------------------


class TestBasicEnforcement:
    def test_under_limit_allows(self):
        limiter = RateLimiter(max_requests=5, window_seconds=60)
        for _ in range(5):
            limiter.check("user-1")

    def test_at_limit_raises_429(self):
        limiter = RateLimiter(max_requests=3, window_seconds=60)
        for _ in range(3):
            limiter.check("user-1")
        with pytest.raises(HTTPException) as exc_info:
            limiter.check("user-1")
        assert exc_info.value.status_code == 429

    def test_429_detail_includes_limit_info(self):
        limiter = RateLimiter(max_requests=2, window_seconds=30)
        limiter.check("user-1")
        limiter.check("user-1")
        with pytest.raises(HTTPException) as exc_info:
            limiter.check("user-1")
        assert "2" in exc_info.value.detail
        assert "30" in exc_info.value.detail

    def test_different_users_have_separate_limits(self):
        limiter = RateLimiter(max_requests=2, window_seconds=60)
        limiter.check("user-1")
        limiter.check("user-1")
        limiter.check("user-2")  # should not raise

    def test_user_1_blocked_does_not_affect_user_2(self):
        limiter = RateLimiter(max_requests=1, window_seconds=60)
        limiter.check("user-1")
        with pytest.raises(HTTPException):
            limiter.check("user-1")
        limiter.check("user-2")  # independent — should not raise


# ---------------------------------------------------------------------------
# Sliding window behavior
# ---------------------------------------------------------------------------


class TestSlidingWindow:
    def test_old_entries_pruned(self):
        """Requests outside the window should be pruned, freeing capacity."""
        limiter = RateLimiter(max_requests=2, window_seconds=1)
        limiter.check("user-1")
        limiter.check("user-1")
        # Manually age the timestamps beyond the 1s window
        limiter._requests["user-1"] = [time.monotonic() - 2]
        # Should be allowed now (old entry pruned)
        limiter.check("user-1")
        # Verify pruning actually happened: only 1 entry (the new one)
        assert len(limiter._requests["user-1"]) == 1

    def test_mixed_old_and_new_entries(self):
        limiter = RateLimiter(max_requests=3, window_seconds=10)
        now = time.monotonic()
        # 2 old entries (expired) + 2 recent entries = 2 active, limit is 3
        limiter._requests["user-1"] = [now - 20, now - 15, now - 0.1, now - 0.05]
        limiter.check("user-1")  # should succeed (2 active + 1 new = 3)
        # Verify: old entries pruned, only active entries remain
        assert len(limiter._requests["user-1"]) == 3  # 2 recent + 1 new

    def test_exactly_at_boundary_kept(self):
        """Entry within the window should still count."""
        limiter = RateLimiter(max_requests=2, window_seconds=60)
        now = time.monotonic()
        limiter._requests["user-1"] = [now - 59, now - 0.1]
        with pytest.raises(HTTPException) as exc_info:
            limiter.check("user-1")
        assert exc_info.value.status_code == 429

    def test_entry_just_past_boundary_pruned(self):
        """Entry past the window boundary should be pruned."""
        limiter = RateLimiter(max_requests=2, window_seconds=60)
        now = time.monotonic()
        limiter._requests["user-1"] = [now - 61, now - 0.1]  # 61s ago = outside 60s window
        limiter.check("user-1")  # should succeed: 1 active + 1 new = 2


# ---------------------------------------------------------------------------
# Redis backend
# ---------------------------------------------------------------------------


class TestRedisBackend:
    """Tests for _check_redis using mocked Redis client."""

    def _make_redis_mock(self, zcard_count=0):
        """Create a mock Redis client with pipeline support."""
        mock_pipe = MagicMock()
        mock_pipe.execute.return_value = [
            None,         # zremrangebyscore result
            zcard_count,  # zcard result
            None,         # zadd result
            None,         # expire result
        ]
        mock_redis = MagicMock()
        mock_redis.pipeline.return_value = mock_pipe
        return mock_redis, mock_pipe

    def test_under_limit_allows(self):
        """Redis check should allow requests under the limit."""
        mock_redis, mock_pipe = self._make_redis_mock(zcard_count=2)
        limiter = RateLimiter(max_requests=5, window_seconds=60)
        with patch("rate_limit.redis_client") as mock_rc:
            mock_rc.is_enabled.return_value = True
            mock_rc.get_sync.return_value = mock_redis
            limiter.check("user-1")  # should not raise

    def test_at_limit_raises_429(self):
        """Redis check should raise 429 when at limit."""
        mock_redis, mock_pipe = self._make_redis_mock(zcard_count=5)
        limiter = RateLimiter(max_requests=5, window_seconds=60)
        with patch("rate_limit.redis_client") as mock_rc:
            mock_rc.is_enabled.return_value = True
            mock_rc.get_sync.return_value = mock_redis
            with pytest.raises(HTTPException) as exc_info:
                limiter.check("user-1")
            assert exc_info.value.status_code == 429
            # Should remove the just-added entry on rejection
            mock_redis.zrem.assert_called_once()

    def test_pipeline_uses_correct_key(self):
        """Pipeline operations should use 'rl:{user_id}' key format."""
        mock_redis, mock_pipe = self._make_redis_mock(zcard_count=0)
        limiter = RateLimiter(max_requests=5, window_seconds=60)
        with patch("rate_limit.redis_client") as mock_rc:
            mock_rc.is_enabled.return_value = True
            mock_rc.get_sync.return_value = mock_redis
            limiter.check("user-42")
        # Verify the pipeline used the correct key
        mock_pipe.zremrangebyscore.assert_called_once()
        args = mock_pipe.zremrangebyscore.call_args[0]
        assert args[0] == "rl:user-42"

    def test_sets_expiration_on_key(self):
        """Pipeline should set TTL on the sorted set key."""
        mock_redis, mock_pipe = self._make_redis_mock(zcard_count=0)
        limiter = RateLimiter(max_requests=5, window_seconds=60)
        with patch("rate_limit.redis_client") as mock_rc:
            mock_rc.is_enabled.return_value = True
            mock_rc.get_sync.return_value = mock_redis
            limiter.check("user-1")
        mock_pipe.expire.assert_called_once()
        args = mock_pipe.expire.call_args[0]
        assert args[1] == 61  # window_seconds + 1

    def test_redis_error_fails_open(self):
        """Redis errors should fail open (allow the request)."""
        mock_redis = MagicMock()
        mock_redis.pipeline.side_effect = ConnectionError("Redis down")
        limiter = RateLimiter(max_requests=1, window_seconds=60)
        with patch("rate_limit.redis_client") as mock_rc:
            mock_rc.is_enabled.return_value = True
            mock_rc.get_sync.return_value = mock_redis
            # Should not raise — fails open
            limiter.check("user-1")

    def test_redis_error_does_not_fallback_to_local(self):
        """Redis failure should not silently fall back to local check."""
        mock_redis = MagicMock()
        mock_redis.pipeline.side_effect = ConnectionError("Redis down")
        limiter = RateLimiter(max_requests=1, window_seconds=60)
        with patch("rate_limit.redis_client") as mock_rc:
            mock_rc.is_enabled.return_value = True
            mock_rc.get_sync.return_value = mock_redis
            limiter.check("user-1")
        # Local requests dict should be empty (not used as fallback)
        assert len(limiter._requests["user-1"]) == 0


# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------


class TestEdgeCases:
    def test_first_request_always_allowed(self):
        limiter = RateLimiter(max_requests=1, window_seconds=60)
        limiter.check("new-user")

    def test_limit_of_one(self):
        limiter = RateLimiter(max_requests=1, window_seconds=60)
        limiter.check("user-1")
        with pytest.raises(HTTPException) as exc_info:
            limiter.check("user-1")
        assert exc_info.value.status_code == 429

    def test_empty_string_user_id(self):
        """Empty user ID should still work as a valid key."""
        limiter = RateLimiter(max_requests=1, window_seconds=60)
        limiter.check("")
        with pytest.raises(HTTPException):
            limiter.check("")
