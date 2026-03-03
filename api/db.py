"""PostgreSQL database for users and API keys."""

import hashlib
import json
import secrets
import logging
import time
from datetime import datetime, timezone

from passlib.hash import bcrypt
from psycopg.errors import UniqueViolation

from pool import get_pool
import redis_client

logger = logging.getLogger("engram")

# API key validation cache: key_hash -> (user_dict, cached_at)
_key_cache: dict[str, tuple[dict, float]] = {}
_KEY_CACHE_TTL = 300  # 5 minutes

# Throttle last_used updates: key_hash -> last_update_time
_last_used_updates: dict[str, float] = {}
_LAST_USED_INTERVAL = 60  # seconds


def init_db():
    """Create auth tables if they don't exist."""
    pool = get_pool()
    with pool.connection() as conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS users (
                id SERIAL PRIMARY KEY,
                email TEXT UNIQUE NOT NULL,
                password_hash TEXT NOT NULL,
                display_name TEXT NOT NULL,
                created_at TIMESTAMPTZ NOT NULL DEFAULT now()
            )
        """)
        conn.execute("""
            CREATE TABLE IF NOT EXISTS api_keys (
                id SERIAL PRIMARY KEY,
                user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                key_hash TEXT UNIQUE NOT NULL,
                name TEXT NOT NULL,
                created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                last_used TIMESTAMPTZ
            )
        """)
        conn.commit()
    logger.info("Auth database initialized (PostgreSQL)")


def create_user(email: str, password: str, display_name: str) -> dict:
    """Create a new user. Returns user dict. Raises UniqueViolation if email exists."""
    password_hash = bcrypt.hash(password)
    pool = get_pool()
    with pool.connection() as conn:
        row = conn.execute(
            "INSERT INTO users (email, password_hash, display_name) VALUES (%s, %s, %s) RETURNING id, email, display_name",
            (email, password_hash, display_name),
        ).fetchone()
        conn.commit()
    return {"id": row[0], "email": row[1], "display_name": row[2]}


def authenticate_user(email: str, password: str) -> dict | None:
    """Verify email/password. Returns user dict or None."""
    pool = get_pool()
    with pool.connection() as conn:
        row = conn.execute(
            "SELECT id, email, display_name, password_hash FROM users WHERE email = %s",
            (email,),
        ).fetchone()
    if row is None:
        return None
    if not bcrypt.verify(password, row[3]):
        return None
    return {"id": row[0], "email": row[1], "display_name": row[2]}


def get_user_by_id(user_id: int) -> dict | None:
    """Look up user by ID. Returns user dict or None."""
    pool = get_pool()
    with pool.connection() as conn:
        row = conn.execute(
            "SELECT id, email, display_name FROM users WHERE id = %s",
            (user_id,),
        ).fetchone()
    if row is None:
        return None
    return {"id": row[0], "email": row[1], "display_name": row[2]}


def create_api_key(user_id: int, name: str) -> str:
    """Create an API key. Returns the raw key (only shown once)."""
    raw_key = "engram_" + secrets.token_urlsafe(32)
    key_hash = hashlib.sha256(raw_key.encode()).hexdigest()
    pool = get_pool()
    with pool.connection() as conn:
        conn.execute(
            "INSERT INTO api_keys (user_id, key_hash, name) VALUES (%s, %s, %s)",
            (user_id, key_hash, name),
        )
        conn.commit()
    return raw_key


def validate_api_key(raw_key: str) -> dict | None:
    """Validate an API key. Returns user dict or None. Updates last_used (throttled)."""
    key_hash = hashlib.sha256(raw_key.encode()).hexdigest()

    if redis_client.is_enabled():
        return _validate_api_key_redis(key_hash)
    return _validate_api_key_local(key_hash)


def _validate_api_key_redis(key_hash: str) -> dict | None:
    """Validate via Redis cache."""
    r = redis_client.get_sync()
    cache_key = f"auth:key:{key_hash}"

    # Check Redis cache
    cached = r.get(cache_key)
    if cached is not None:
        user_dict = json.loads(cached)
        # Throttle last_used: SET NX with 60s TTL (only sets if not already set)
        lu_key = f"auth:lu:{key_hash}"
        if r.set(lu_key, "1", ex=_LAST_USED_INTERVAL, nx=True):
            try:
                pool = get_pool()
                with pool.connection() as conn:
                    conn.execute(
                        "UPDATE api_keys SET last_used = %s WHERE key_hash = %s",
                        (datetime.now(timezone.utc), key_hash),
                    )
                    conn.commit()
            except Exception:
                pass
        return user_dict

    # Cache miss — query DB
    pool = get_pool()
    with pool.connection() as conn:
        row = conn.execute(
            """SELECT ak.id as key_id, ak.user_id, u.email, u.display_name
               FROM api_keys ak JOIN users u ON ak.user_id = u.id
               WHERE ak.key_hash = %s""",
            (key_hash,),
        ).fetchone()
        if row is None:
            return None
        conn.execute(
            "UPDATE api_keys SET last_used = %s WHERE id = %s",
            (datetime.now(timezone.utc), row[0]),
        )
        conn.commit()

    user_dict = {"id": row[1], "email": row[2], "display_name": row[3]}
    r.setex(cache_key, _KEY_CACHE_TTL, json.dumps(user_dict))
    r.set(f"auth:lu:{key_hash}", "1", ex=_LAST_USED_INTERVAL)
    return user_dict


def _validate_api_key_local(key_hash: str) -> dict | None:
    """Validate via in-memory cache (original behavior)."""
    now = time.monotonic()

    # Check cache first
    cached = _key_cache.get(key_hash)
    if cached is not None:
        user_dict, cached_at = cached
        if now - cached_at < _KEY_CACHE_TTL:
            # Throttle last_used update
            last_update = _last_used_updates.get(key_hash, 0)
            if now - last_update >= _LAST_USED_INTERVAL:
                try:
                    pool = get_pool()
                    with pool.connection() as conn:
                        conn.execute(
                            "UPDATE api_keys SET last_used = %s WHERE key_hash = %s",
                            (datetime.now(timezone.utc), key_hash),
                        )
                        conn.commit()
                    _last_used_updates[key_hash] = now
                except Exception:
                    pass  # non-critical
            return user_dict

    pool = get_pool()
    with pool.connection() as conn:
        row = conn.execute(
            """SELECT ak.id as key_id, ak.user_id, u.email, u.display_name
               FROM api_keys ak JOIN users u ON ak.user_id = u.id
               WHERE ak.key_hash = %s""",
            (key_hash,),
        ).fetchone()
        if row is None:
            return None
        conn.execute(
            "UPDATE api_keys SET last_used = %s WHERE id = %s",
            (datetime.now(timezone.utc), row[0]),
        )
        conn.commit()

    user_dict = {"id": row[1], "email": row[2], "display_name": row[3]}
    _key_cache[key_hash] = (user_dict, now)
    _last_used_updates[key_hash] = now
    return user_dict


def list_api_keys(user_id: int) -> list[dict]:
    """List all API keys for a user (without hashes)."""
    pool = get_pool()
    with pool.connection() as conn:
        rows = conn.execute(
            "SELECT id, name, created_at, last_used FROM api_keys WHERE user_id = %s ORDER BY created_at DESC",
            (user_id,),
        ).fetchall()
    return [
        {
            "id": r[0],
            "name": r[1],
            "created_at": r[2].isoformat() if r[2] else None,
            "last_used": r[3].isoformat() if r[3] else None,
        }
        for r in rows
    ]


def delete_api_key(user_id: int, key_id: int) -> bool:
    """Delete an API key. Returns True if deleted. Invalidates cache immediately."""
    pool = get_pool()
    with pool.connection() as conn:
        # Get the key hash before deleting so we can clear the cache
        row = conn.execute(
            "SELECT key_hash FROM api_keys WHERE id = %s AND user_id = %s", (key_id, user_id)
        ).fetchone()
        if row is None:
            return False
        key_hash = row[0]
        conn.execute(
            "DELETE FROM api_keys WHERE id = %s AND user_id = %s", (key_id, user_id)
        )
        conn.commit()

    # Invalidate cache — Redis (cross-instance) or in-memory
    if redis_client.is_enabled():
        r = redis_client.get_sync()
        r.delete(f"auth:key:{key_hash}", f"auth:lu:{key_hash}")
    else:
        _key_cache.pop(key_hash, None)
        _last_used_updates.pop(key_hash, None)
    return True
