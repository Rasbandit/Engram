"""Shared PostgreSQL connection pool singleton."""

import logging

from psycopg_pool import ConnectionPool

from config import DATABASE_URL, PG_POOL_MAX

logger = logging.getLogger("brain-api")

_pool: ConnectionPool | None = None


def get_pool() -> ConnectionPool:
    """Return the shared connection pool, creating it on first call."""
    global _pool
    if _pool is None:
        _pool = ConnectionPool(DATABASE_URL, min_size=2, max_size=PG_POOL_MAX, open=True)
        logger.info("PostgreSQL connection pool initialized (max_size=%d)", PG_POOL_MAX)
    return _pool


def close_pool() -> None:
    """Close the connection pool (call on shutdown)."""
    global _pool
    if _pool is not None:
        _pool.close()
        _pool = None
        logger.info("PostgreSQL connection pool closed")
