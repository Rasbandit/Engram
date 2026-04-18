"""Test 62: Encrypted vault round-trip via HTTP API.

Registers a vault, enables encryption directly in the DB (the vault
changeset does not cast `encrypted` yet — the toggle UI is a future
phase), writes a note, reads it back, asserts the API returns plaintext.

This is the acceptance test for end-to-end encryption across a real HTTP
boundary. It runs in the api_only CI job (no Obsidian, no Clerk needed).

Design note: we cannot set encrypted=true through the public API today
because Vault.changeset/2 only casts a restricted field list. Until the
encryption-toggle endpoint ships we patch the DB row directly via psql,
mirroring the same docker-exec pattern used in cleanup.py.
"""

from __future__ import annotations

import logging
import os
import subprocess
import time

import pytest
import requests

API_URL = os.environ.get("ENGRAM_API_URL") or "http://localhost:8100/api"
CI_POSTGRES_CONTAINER = os.environ.get("CI_POSTGRES_CONTAINER", "engram-postgres-1")

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# DB helpers
# ---------------------------------------------------------------------------


def _enable_vault_encryption(vault_id: int) -> None:
    """Flip vaults.encrypted = true for a specific vault ID via psql.

    Uses the same docker-exec pattern as cleanup.py. Safe: vault_id is an
    integer supplied by the test, never from user input.
    """
    sql = f"UPDATE vaults SET encrypted = true WHERE id = {int(vault_id)};\n"
    cmd = [
        "docker", "exec", "-i", CI_POSTGRES_CONTAINER,
        "psql", "-U", "engram", "-d", "engram",
    ]
    result = subprocess.run(cmd, input=sql, capture_output=True, text=True, timeout=15)
    if result.returncode != 0:
        stderr = result.stderr.strip()
        if "No such container" in stderr:
            pytest.skip(f"CI postgres container {CI_POSTGRES_CONTAINER!r} not found — skipping encrypted-vault E2E")
        raise RuntimeError(f"psql update failed: {stderr}")


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


class TestEncryptedVaultRoundTrip:
    """Write and read a note from an encrypted vault via HTTP."""

    def test_encrypted_vault_round_trip(self, api_sync, sync_client_id):
        """Plaintext written to an encrypted vault is returned as plaintext on read."""
        # 1. Find the vault pre-registered in the api_sync fixture by client_id
        #    (avoids hitting free-tier limit which allows 1 vault per user).
        vaults = api_sync.list_vaults()
        vault = next((v for v in vaults if v.get("client_id") == sync_client_id), None)
        assert vault is not None, f"No vault found with client_id={sync_client_id}. Vaults: {vaults}"
        vault_id = vault["id"]

        # 2. Enable encryption at the DB level (toggle endpoint is a future phase)
        _enable_vault_encryption(vault_id)

        # 3. Build an ApiClient that sends X-Vault-ID so vault-scoped endpoints resolve
        vault_client = api_sync.with_vault(vault_id)

        plaintext = "secret diary entry — only plaintext should come back"
        note_path = "journal/today.md"

        try:
            # 4. Upsert note
            resp = vault_client.session.post(
                f"{API_URL}/notes",
                json={"path": note_path, "content": plaintext, "mtime": time.time()},
                timeout=10,
            )
            assert resp.ok, f"upsert_note failed: {resp.status_code} {resp.text[:300]}"

            # 5. Read back — must return decrypted plaintext
            note = vault_client.get_note(note_path)
            assert note is not None, f"Note not found after upsert: {note_path}"
            assert note["content"] == plaintext, (
                f"Expected plaintext content, got: {note['content'][:100]!r}"
            )
        finally:
            # Teardown: disable encryption so subsequent tests using this vault aren't affected
            sql = f"UPDATE vaults SET encrypted = false WHERE id = {int(vault_id)};\n"
            cmd = [
                "docker", "exec", "-i", CI_POSTGRES_CONTAINER,
                "psql", "-U", "engram", "-d", "engram",
            ]
            subprocess.run(cmd, input=sql, capture_output=True, text=True, timeout=15)
