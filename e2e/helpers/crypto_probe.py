"""Database + Qdrant probes for at-rest encryption assertions.

Used by E2E tests that need to verify ciphertext is actually at rest
(not just that the API returns plaintext). Mirrors the docker-exec psql
pattern from cleanup.py.
"""

from __future__ import annotations

import json
import logging
import os
import subprocess
import time

import requests

logger = logging.getLogger(__name__)

CI_POSTGRES_CONTAINER = os.environ.get("CI_POSTGRES_CONTAINER", "engram-postgres-1")
QDRANT_URL = os.environ.get("QDRANT_URL", "http://10.0.20.201:6333")
QDRANT_COLLECTION = os.environ.get("QDRANT_COLLECTION", "ci_test_notes")


def _psql(sql: str, *, fetch: bool = False) -> str:
    """Run SQL via docker exec psql. Returns stdout (or raises on error)."""
    args = ["-v", "ON_ERROR_STOP=1"]
    if fetch:
        args += ["-t", "-A", "-F", "|"]  # tuples-only, unaligned, pipe-separated
    cmd = ["docker", "exec", "-i", CI_POSTGRES_CONTAINER, "psql", "-U", "engram", "-d", "engram", *args]
    result = subprocess.run(cmd, input=sql, capture_output=True, text=True, timeout=15)
    if result.returncode != 0:
        raise RuntimeError(f"psql failed: {result.stderr.strip()}\nSQL: {sql!r}")
    return result.stdout.strip()


def _fetch_note_row(vault_id: int, path: str) -> dict:
    """SELECT the encryption columns for a note. Returns dict or raises AssertionError
    if the note doesn't exist."""
    sql = (
        f"\\set target_path '{path}'\n"
        f"SELECT content IS NULL, title IS NULL, "
        f"content_ciphertext IS NOT NULL, content_nonce IS NOT NULL, "
        f"title_ciphertext IS NOT NULL, title_nonce IS NOT NULL, tags_ciphertext IS NOT NULL "
        f"FROM notes WHERE vault_id = {int(vault_id)} AND path = :'target_path';"
    )
    out = _psql(sql, fetch=True)
    assert out, f"Note not found in DB: vault_id={vault_id} path={path!r}"
    line = out.splitlines()[0]
    c_null, t_null, c_ct, c_n, t_ct, t_n, tag_ct = line.split("|")
    return {
        "content_is_null": c_null == "t",
        "title_is_null": t_null == "t",
        "content_ciphertext_present": c_ct == "t",
        "content_nonce_present": c_n == "t",
        "title_ciphertext_present": t_ct == "t",
        "title_nonce_present": t_n == "t",
        "tags_ciphertext_present": tag_ct == "t",
    }


def assert_note_ciphertext_at_rest(vault_id: int, path: str) -> None:
    """Assert the note at (vault_id, path) is stored as ciphertext."""
    row = _fetch_note_row(vault_id, path)
    failures = []
    if not row["content_is_null"]:
        failures.append("content is not NULL")
    if not row["title_is_null"]:
        failures.append("title is not NULL")
    if not row["content_ciphertext_present"]:
        failures.append("content_ciphertext is NULL")
    if not row["content_nonce_present"]:
        failures.append("content_nonce is NULL")
    if not row["title_ciphertext_present"]:
        failures.append("title_ciphertext is NULL")
    if not row["title_nonce_present"]:
        failures.append("title_nonce is NULL")
    assert not failures, (
        f"Expected ciphertext at rest for vault_id={vault_id} path={path!r}; "
        f"failures: {failures}"
    )


def assert_note_plaintext_at_rest(vault_id: int, path: str) -> None:
    """Inverse. Content column populated, ciphertext columns NULL."""
    row = _fetch_note_row(vault_id, path)
    failures = []
    if row["content_is_null"]:
        failures.append("content is NULL (expected plaintext)")
    if row["content_ciphertext_present"]:
        failures.append("content_ciphertext is set (expected NULL)")
    if row["content_nonce_present"]:
        failures.append("content_nonce is set (expected NULL)")
    if row["title_ciphertext_present"]:
        failures.append("title_ciphertext is set (expected NULL)")
    if row["title_nonce_present"]:
        failures.append("title_nonce is set (expected NULL)")
    assert not failures, (
        f"Expected plaintext at rest for vault_id={vault_id} path={path!r}; "
        f"failures: {failures}"
    )
