"""Cleanup helpers — removes test data from local CI postgres and local vaults."""

from __future__ import annotations

import logging
import os
import re
import shutil
import subprocess
from pathlib import Path

logger = logging.getLogger(__name__)

VAULT_PATHS = [
    Path("/tmp/e2e-vault-a"),
    Path("/tmp/e2e-vault-b"),
    Path("/tmp/e2e-vault-c"),
]

# CI compose project name — matches the directory name where docker-compose.ci.yml lives
CI_POSTGRES_CONTAINER = os.environ.get("CI_POSTGRES_CONTAINER", "engram-postgres-1")


_SAFE_EMAIL_PATTERN = re.compile(r"^[a-zA-Z0-9._@%+-]+$")


def cleanup_test_data(email_pattern: str = "e2e-%@test.local") -> None:
    """Run cleanup SQL via docker exec against the local CI postgres container.

    Deletes all users/notes/attachments/api_keys matching the email pattern.
    FK-safe deletion order. Uses psql variable binding to avoid SQL injection.
    """
    if not _SAFE_EMAIL_PATTERN.match(email_pattern):
        raise ValueError(f"Unsafe email pattern rejected: {email_pattern!r}")

    # Use psql -v to pass the pattern as a variable, then reference it with :'pat'
    sql = (
        "DELETE FROM api_keys WHERE user_id IN (SELECT id FROM users WHERE email LIKE :'pat'); "
        "DELETE FROM notes WHERE user_id IN (SELECT id::text FROM users WHERE email LIKE :'pat'); "
        "DELETE FROM attachments WHERE user_id IN (SELECT id::text FROM users WHERE email LIKE :'pat'); "
        "DELETE FROM users WHERE email LIKE :'pat';"
    )

    cmd = [
        "docker", "exec", CI_POSTGRES_CONTAINER,
        "psql", "-U", "engram", "-d", "engram",
        "-v", f"pat={email_pattern}",
        "-c", sql,
    ]

    logger.info("Running cleanup SQL on %s (pattern: %s)", CI_POSTGRES_CONTAINER, email_pattern)
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)

    if result.returncode != 0:
        logger.error("Cleanup SQL failed: %s", result.stderr)
        raise RuntimeError(f"Cleanup failed: {result.stderr}")

    logger.info("Cleanup SQL output: %s", result.stdout.strip())


def cleanup_vaults() -> None:
    """Remove all E2E vault directories."""
    for vault in VAULT_PATHS:
        if vault.exists():
            shutil.rmtree(vault)
            logger.info("Removed %s", vault)


def full_cleanup() -> None:
    """Run both DB and vault cleanup."""
    cleanup_test_data()
    cleanup_vaults()


if __name__ == "__main__":
    """Allow running cleanup standalone: python -m e2e.helpers.cleanup"""
    logging.basicConfig(level=logging.INFO)
    full_cleanup()
    print("Cleanup complete.")
