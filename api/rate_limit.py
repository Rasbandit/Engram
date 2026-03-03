"""Per-user sliding window rate limiter with optional Redis backend."""

import logging
import time
from collections import defaultdict

from fastapi import Depends, HTTPException

from auth import get_current_user_api_key
from config import RATE_LIMIT_RPM
import redis_client

logger = logging.getLogger("engram")


class RateLimiter:
    """Sliding window rate limiter keyed by user ID."""

    def __init__(self, max_requests: int = 120, window_seconds: int = 60):
        self.max_requests = max_requests
        self.window_seconds = window_seconds
        self._requests: dict[str, list[float]] = defaultdict(list)

    def check(self, user_id: str) -> None:
        """Raise HTTPException 429 if rate limit exceeded."""
        if redis_client.is_enabled():
            self._check_redis(user_id)
        else:
            self._check_local(user_id)

    def _check_local(self, user_id: str) -> None:
        """In-memory sliding window (original behavior)."""
        now = time.monotonic()
        cutoff = now - self.window_seconds
        timestamps = self._requests[user_id]

        # Prune old entries
        self._requests[user_id] = [t for t in timestamps if t > cutoff]
        timestamps = self._requests[user_id]

        if len(timestamps) >= self.max_requests:
            raise HTTPException(
                status_code=429,
                detail=f"Rate limit exceeded ({self.max_requests} requests per {self.window_seconds}s)",
            )
        timestamps.append(now)

    def _check_redis(self, user_id: str) -> None:
        """Redis sorted set sliding window — fail-open on error."""
        try:
            r = redis_client.get_sync()
            key = f"rl:{user_id}"
            now = time.time()
            cutoff = now - self.window_seconds

            pipe = r.pipeline()
            pipe.zremrangebyscore(key, "-inf", cutoff)
            pipe.zcard(key)
            pipe.zadd(key, {str(now): now})
            pipe.expire(key, self.window_seconds + 1)
            results = pipe.execute()

            count = results[1]  # zcard result
            if count >= self.max_requests:
                # Remove the entry we just added since we're rejecting
                r.zrem(key, str(now))
                raise HTTPException(
                    status_code=429,
                    detail=f"Rate limit exceeded ({self.max_requests} requests per {self.window_seconds}s)",
                )
        except HTTPException:
            raise
        except Exception:
            logger.warning("Redis rate limit check failed, allowing request (fail-open)")


_limiter = RateLimiter(max_requests=RATE_LIMIT_RPM, window_seconds=60)


def rate_limit(user: dict = Depends(get_current_user_api_key)) -> dict:
    """FastAPI dependency that enforces rate limiting on the authenticated user."""
    _limiter.check(str(user["id"]))
    return user
