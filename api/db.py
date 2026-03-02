"""SQLite database for users and API keys."""

import hashlib
import secrets
import sqlite3
import logging
from datetime import datetime, timezone

from passlib.hash import bcrypt

from config import DB_PATH

logger = logging.getLogger("brain-api")

_conn: sqlite3.Connection | None = None


def _get_conn() -> sqlite3.Connection:
    global _conn
    if _conn is None:
        _conn = sqlite3.connect(DB_PATH, check_same_thread=False)
        _conn.row_factory = sqlite3.Row
        _conn.execute("PRAGMA journal_mode=WAL")
        _conn.execute("PRAGMA foreign_keys=ON")
    return _conn


def init_db():
    """Create tables if they don't exist."""
    conn = _get_conn()
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            email TEXT UNIQUE NOT NULL,
            password_hash TEXT NOT NULL,
            display_name TEXT NOT NULL,
            created_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS api_keys (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            key_hash TEXT UNIQUE NOT NULL,
            name TEXT NOT NULL,
            created_at TEXT NOT NULL,
            last_used TEXT
        );
    """)
    conn.commit()
    logger.info("Database initialized at %s", DB_PATH)


def create_user(email: str, password: str, display_name: str) -> dict:
    """Create a new user. Returns user dict. Raises sqlite3.IntegrityError if email exists."""
    conn = _get_conn()
    now = datetime.now(timezone.utc).isoformat()
    password_hash = bcrypt.hash(password)
    cursor = conn.execute(
        "INSERT INTO users (email, password_hash, display_name, created_at) VALUES (?, ?, ?, ?)",
        (email, password_hash, display_name, now),
    )
    conn.commit()
    return {"id": cursor.lastrowid, "email": email, "display_name": display_name}


def authenticate_user(email: str, password: str) -> dict | None:
    """Verify email/password. Returns user dict or None."""
    conn = _get_conn()
    row = conn.execute("SELECT * FROM users WHERE email = ?", (email,)).fetchone()
    if row is None:
        return None
    if not bcrypt.verify(password, row["password_hash"]):
        return None
    return {"id": row["id"], "email": row["email"], "display_name": row["display_name"]}


def get_user_by_id(user_id: int) -> dict | None:
    """Look up user by ID. Returns user dict or None."""
    conn = _get_conn()
    row = conn.execute("SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()
    if row is None:
        return None
    return {"id": row["id"], "email": row["email"], "display_name": row["display_name"]}


def create_api_key(user_id: int, name: str) -> str:
    """Create an API key. Returns the raw key (only shown once)."""
    conn = _get_conn()
    raw_key = "brain_" + secrets.token_urlsafe(32)
    key_hash = hashlib.sha256(raw_key.encode()).hexdigest()
    now = datetime.now(timezone.utc).isoformat()
    conn.execute(
        "INSERT INTO api_keys (user_id, key_hash, name, created_at) VALUES (?, ?, ?, ?)",
        (user_id, key_hash, name, now),
    )
    conn.commit()
    return raw_key


def validate_api_key(raw_key: str) -> dict | None:
    """Validate an API key. Returns user dict or None. Updates last_used."""
    conn = _get_conn()
    key_hash = hashlib.sha256(raw_key.encode()).hexdigest()
    row = conn.execute(
        """SELECT ak.id as key_id, ak.user_id, u.email, u.display_name
           FROM api_keys ak JOIN users u ON ak.user_id = u.id
           WHERE ak.key_hash = ?""",
        (key_hash,),
    ).fetchone()
    if row is None:
        return None
    now = datetime.now(timezone.utc).isoformat()
    conn.execute("UPDATE api_keys SET last_used = ? WHERE id = ?", (now, row["key_id"]))
    conn.commit()
    return {"id": row["user_id"], "email": row["email"], "display_name": row["display_name"]}


def list_api_keys(user_id: int) -> list[dict]:
    """List all API keys for a user (without hashes)."""
    conn = _get_conn()
    rows = conn.execute(
        "SELECT id, name, created_at, last_used FROM api_keys WHERE user_id = ? ORDER BY created_at DESC",
        (user_id,),
    ).fetchall()
    return [dict(row) for row in rows]


def delete_api_key(user_id: int, key_id: int) -> bool:
    """Delete an API key. Returns True if deleted."""
    conn = _get_conn()
    cursor = conn.execute(
        "DELETE FROM api_keys WHERE id = ? AND user_id = ?", (key_id, user_id)
    )
    conn.commit()
    return cursor.rowcount > 0
