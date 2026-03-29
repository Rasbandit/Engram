"""PostgreSQL client log store — stores plugin error/lifecycle logs for remote debugging."""

import logging
from datetime import datetime, timedelta, timezone

import psycopg

from config import LOG_RETENTION_DAYS
from pool import get_pool

logger = logging.getLogger("engram")


def init_log_db():
    """Create client_logs table and indexes if they don't exist."""
    pool = get_pool()
    try:
        with pool.connection() as conn:
            conn.execute("""
                CREATE TABLE IF NOT EXISTS client_logs (
                    id SERIAL PRIMARY KEY,
                    user_id TEXT NOT NULL,
                    ts TIMESTAMPTZ NOT NULL,
                    level TEXT NOT NULL DEFAULT 'info',
                    category TEXT NOT NULL DEFAULT '',
                    message TEXT NOT NULL DEFAULT '',
                    stack TEXT,
                    plugin_version TEXT NOT NULL DEFAULT '',
                    platform TEXT NOT NULL DEFAULT '',
                    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
                )
            """)
            conn.execute("""
                CREATE INDEX IF NOT EXISTS idx_client_logs_user_created
                ON client_logs(user_id, created_at DESC)
            """)
            conn.execute("""
                CREATE INDEX IF NOT EXISTS idx_client_logs_user_level
                ON client_logs(user_id, level)
            """)
            conn.commit()
    except psycopg.errors.UniqueViolation:
        pass
    logger.info("PostgreSQL client log store initialized")


def insert_logs(user_id: str, entries: list[dict]) -> int:
    """Batch-insert log entries. Returns count inserted.

    Also deletes entries older than LOG_RETENTION_DAYS (piggyback cleanup).
    """
    if not entries:
        return 0

    pool = get_pool()
    with pool.connection() as conn:
        values = []
        params = []
        for e in entries:
            values.append("(%s, %s, %s, %s, %s, %s, %s, %s)")
            params.extend([
                user_id,
                e["ts"],
                e.get("level", "info"),
                e.get("category", ""),
                e.get("message", ""),
                e.get("stack"),
                e.get("plugin_version", ""),
                e.get("platform", ""),
            ])

        sql = (
            "INSERT INTO client_logs (user_id, ts, level, category, message, stack, plugin_version, platform) "
            f"VALUES {', '.join(values)}"
        )
        conn.execute(sql, params)

        # Piggyback cleanup: delete old entries for this user
        cutoff = datetime.now(timezone.utc) - timedelta(days=LOG_RETENTION_DAYS)
        conn.execute(
            "DELETE FROM client_logs WHERE user_id = %s AND created_at < %s",
            (user_id, cutoff),
        )
        conn.commit()

    return len(entries)


def get_logs(
    user_id: str,
    level: str | None = None,
    since: datetime | None = None,
    limit: int = 200,
) -> list[dict]:
    """Get log entries for a user, newest first."""
    pool = get_pool()
    conditions = ["user_id = %s"]
    params: list = [user_id]

    if level:
        conditions.append("level = %s")
        params.append(level)
    if since:
        conditions.append("ts >= %s")
        params.append(since)

    params.append(min(limit, 1000))
    where = " AND ".join(conditions)

    with pool.connection() as conn:
        rows = conn.execute(
            f"""
            SELECT id, ts, level, category, message, stack, plugin_version, platform, created_at
            FROM client_logs
            WHERE {where}
            ORDER BY ts DESC
            LIMIT %s
            """,
            params,
        ).fetchall()

    return [
        {
            "id": r[0],
            "ts": r[1].isoformat(),
            "level": r[2],
            "category": r[3],
            "message": r[4],
            "stack": r[5],
            "plugin_version": r[6],
            "platform": r[7],
            "created_at": r[8].isoformat(),
        }
        for r in rows
    ]


def delete_old_logs(user_id: str, before: datetime) -> int:
    """Hard-delete logs older than a given timestamp. Returns count deleted."""
    pool = get_pool()
    with pool.connection() as conn:
        cursor = conn.execute(
            "DELETE FROM client_logs WHERE user_id = %s AND created_at < %s",
            (user_id, before),
        )
        conn.commit()
    return cursor.rowcount
