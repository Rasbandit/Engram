"""Optional Redis client — set REDIS_URL to enable, otherwise all ops are no-ops."""

import logging
from typing import Optional

from config import REDIS_URL

logger = logging.getLogger("engram")

_sync_client = None
_async_client = None


def is_enabled() -> bool:
    return REDIS_URL is not None


def get_sync() -> Optional["redis.Redis"]:
    """Return a sync Redis client (lazy-init). None if Redis not configured."""
    global _sync_client
    if not is_enabled():
        return None
    if _sync_client is None:
        import redis
        _sync_client = redis.Redis.from_url(REDIS_URL, decode_responses=True)
        logger.info("Redis sync client connected: %s", REDIS_URL)
    return _sync_client


def get_async() -> Optional["redis.asyncio.Redis"]:
    """Return an async Redis client (lazy-init). None if Redis not configured."""
    global _async_client
    if not is_enabled():
        return None
    if _async_client is None:
        import redis.asyncio
        _async_client = redis.asyncio.Redis.from_url(REDIS_URL, decode_responses=True)
        logger.info("Redis async client connected: %s", REDIS_URL)
    return _async_client


async def close_redis() -> None:
    """Shutdown Redis connections. No-op if not configured."""
    global _sync_client, _async_client
    if _sync_client is not None:
        _sync_client.close()
        _sync_client = None
    if _async_client is not None:
        await _async_client.aclose()
        _async_client = None
