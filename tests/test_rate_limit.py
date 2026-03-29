"""Unit tests for rate_limit.py — sliding window, 429 enforcement, unlimited mode."""

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
# Unlimited mode (max_requests=0)
# ---------------------------------------------------------------------------


class TestUnlimitedMode:
    def test_zero_allows_all_requests(self):
        limiter = RateLimiter(max_requests=0)
        # Should not raise for any number of calls
        for _ in range(100):
            limiter.check("user-1")

    def test_negative_allows_all_requests(self):
        limiter = RateLimiter(max_requests=-1)
        for _ in range(50):
            limiter.check("user-1")


# ---------------------------------------------------------------------------
# Basic enforcement
# ---------------------------------------------------------------------------


class TestBasicEnforcement:
    def test_under_limit_allows(self):
        limiter = RateLimiter(max_requests=5, window_seconds=60)
        for _ in range(5):
            limiter.check("user-1")  # should not raise

    def test_at_limit_raises_429(self):
        limiter = RateLimiter(max_requests=3, window_seconds=60)
        limiter.check("user-1")
        limiter.check("user-1")
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
        # user-1 is at limit, but user-2 should be fine
        limiter.check("user-2")  # should not raise

    def test_user_1_blocked_does_not_affect_user_2(self):
        limiter = RateLimiter(max_requests=1, window_seconds=60)
        limiter.check("user-1")
        with pytest.raises(HTTPException):
            limiter.check("user-1")
        # user-2 is independent
        limiter.check("user-2")  # should not raise


# ---------------------------------------------------------------------------
# Sliding window behavior
# ---------------------------------------------------------------------------


class TestSlidingWindow:
    def test_old_entries_pruned(self):
        """Requests outside the window should be pruned, freeing capacity."""
        limiter = RateLimiter(max_requests=2, window_seconds=1)

        limiter.check("user-1")
        limiter.check("user-1")
        # At limit now

        # Manually age the timestamps
        limiter._requests["user-1"] = [time.monotonic() - 2]  # 2s ago, outside 1s window

        # Should be allowed now (old entry pruned)
        limiter.check("user-1")

    def test_mixed_old_and_new_entries(self):
        limiter = RateLimiter(max_requests=3, window_seconds=10)
        now = time.monotonic()
        # 2 old entries (expired) + 2 recent entries = 2 active, limit is 3
        limiter._requests["user-1"] = [now - 20, now - 15, now - 0.1, now - 0.05]
        limiter.check("user-1")  # should succeed (2 active + 1 new = 3)

    def test_exactly_at_boundary_kept(self):
        """Entry exactly at the window edge should still count."""
        limiter = RateLimiter(max_requests=2, window_seconds=60)
        now = time.monotonic()
        # Entry exactly at cutoff boundary — monotonic() - 59s is within 60s window
        limiter._requests["user-1"] = [now - 59, now - 0.1]
        with pytest.raises(HTTPException):
            limiter.check("user-1")  # 2 active + 1 = would exceed limit of 2


# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------


class TestEdgeCases:
    def test_first_request_always_allowed(self):
        limiter = RateLimiter(max_requests=1, window_seconds=60)
        limiter.check("new-user")  # should not raise

    def test_limit_of_one(self):
        limiter = RateLimiter(max_requests=1, window_seconds=60)
        limiter.check("user-1")
        with pytest.raises(HTTPException):
            limiter.check("user-1")

    def test_empty_string_user_id(self):
        """Empty user ID should still work as a valid key."""
        limiter = RateLimiter(max_requests=1, window_seconds=60)
        limiter.check("")
        with pytest.raises(HTTPException):
            limiter.check("")
