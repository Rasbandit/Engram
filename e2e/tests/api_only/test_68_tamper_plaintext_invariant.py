"""Test 68: Tamper-plaintext invariant — controllers source from ciphertext.

Phase B.2.6: lookup uses `path_hmac`, not the plaintext `path` column;
GET responses are decrypted from `path_ciphertext` / `folder_ciphertext`,
not read from the plaintext columns. This test proves both halves at
the HTTP boundary by directly corrupting the plaintext columns via SQL
and verifying the API still returns the correct value.

If a controller silently falls back to the plaintext column, this test
catches it. Once Phase B.3 drops the plaintext columns the test still
applies — the corruption simply has no effect, and the assertions pass.

API-only (no Obsidian, no Clerk). Reuses the encrypted-vault toggle
pattern from test_62.
"""

from __future__ import annotations

import logging
import os
import time

import pytest

from helpers.crypto_probe import (
    backdate_decrypt_requested,
    backdate_last_toggle,
    tamper_note_plaintext_columns,
    wait_for_encryption_status,
)

API_URL = os.environ.get("ENGRAM_API_URL") or "http://localhost:8100/api"

logger = logging.getLogger(__name__)


@pytest.fixture
def reset_vault_encryption(api_sync):
    yield
    vaults = api_sync.list_vaults()
    if not vaults:
        return
    vault_id = vaults[0]["id"]
    resp = api_sync.session.get(
        f"{API_URL}/vaults/{vault_id}/encryption_progress", timeout=5
    )
    if not resp.ok:
        return
    status = resp.json().get("status")
    if status in ("encrypted", "encrypting"):
        if status == "encrypting":
            wait_for_encryption_status(api_sync, vault_id, "encrypted", timeout=60)
        backdate_last_toggle(vault_id, days=8)
        api_sync.session.post(f"{API_URL}/vaults/{vault_id}/decrypt", timeout=10)
        backdate_decrypt_requested(vault_id, hours=25)
        wait_for_encryption_status(api_sync, vault_id, "none", timeout=60)
        backdate_last_toggle(vault_id, days=8)


class TestTamperPlaintextInvariant:
    """Corrupting the plaintext path/folder columns must not change what
    GET /notes/:path or GET /folders/list returns."""

    def test_get_note_uses_ciphertext_after_plaintext_tamper(
        self, api_sync, reset_vault_encryption
    ):
        vaults = api_sync.list_vaults()
        assert vaults, "api_sync should have a registered vault"
        vault_id = vaults[0]["id"]
        client = api_sync.with_vault(vault_id)

        # 1. Encrypt the vault
        resp = client.session.post(
            f"{API_URL}/vaults/{vault_id}/encrypt", timeout=10
        )
        assert resp.status_code == 202, (
            f"encrypt failed: {resp.status_code} {resp.text[:300]}"
        )
        wait_for_encryption_status(client, vault_id, "encrypted", timeout=30)

        # 2. Write a note (plaintext over the wire, ciphertext at rest)
        ts = int(time.time())
        note_path = f"projects/secret-{ts}.md"
        original_folder = "projects"
        plaintext = f"truly secret payload {ts}"

        resp = client.session.post(
            f"{API_URL}/notes",
            json={
                "path": note_path,
                "content": plaintext,
                "mtime": time.time(),
            },
            timeout=10,
        )
        assert resp.ok, f"upsert failed: {resp.status_code} {resp.text[:300]}"

        # 3. Sanity — read back returns plaintext via ciphertext path
        note = client.get_note(note_path)
        assert note is not None, "Note must exist after upsert"
        assert plaintext in note.get("content", ""), (
            f"Initial GET should return plaintext, got: {note.get('content')!r}"
        )

        # 4. CORRUPT the plaintext path + folder columns directly via SQL.
        #    HMAC + ciphertext columns are untouched.
        tamper_note_plaintext_columns(
            vault_id,
            note_path,
            new_path="CORRUPTED/wrong-path.md",
            new_folder="CORRUPTED/wrong-folder",
        )

        # 5. GET the note by its real path. Lookup goes through path_hmac
        #    (B.2.0) and the response decrypts from ciphertext (B.2.6) —
        #    must succeed and return the original plaintext.
        note_after = client.get_note(note_path)
        assert note_after is not None, (
            "GET /notes/:path must still locate the note via path_hmac "
            "after the plaintext column was corrupted"
        )
        assert plaintext in note_after.get("content", ""), (
            f"GET /notes/:path returned wrong content after tamper. "
            f"Got: {note_after.get('content')!r}"
        )

        # The returned `path` field must equal the original (decrypted from
        # path_ciphertext) — never the corrupted plaintext column value.
        returned_path = note_after.get("path")
        assert returned_path == note_path, (
            f"GET response path must be decrypted from ciphertext, got "
            f"{returned_path!r} (corruption leaked through from plaintext column)"
        )

        # 6. GET /folders/list?folder=projects — must still include this
        #    note. Folder lookup is via folder_hmac (B.2.6); the corrupted
        #    `folder = 'CORRUPTED/wrong-folder'` column must not affect it.
        listing = client.list_folder(original_folder)
        listed_paths = [
            n.get("path") for n in listing.get("notes", []) if isinstance(n, dict)
        ]
        assert note_path in listed_paths, (
            f"Folder listing for {original_folder!r} must include {note_path!r} "
            f"via folder_hmac lookup. Got: {listed_paths}"
        )

        # 7. GET /folders/list with the corrupted folder name must return
        #    NOTHING for our note — proves listing keys off folder_hmac of
        #    the request, not the plaintext column.
        bad_listing = client.list_folder("CORRUPTED/wrong-folder")
        bad_paths = [
            n.get("path") for n in bad_listing.get("notes", []) if isinstance(n, dict)
        ]
        assert note_path not in bad_paths, (
            f"Folder listing keyed off the tampered plaintext column — "
            f"controller must derive folder_hmac from the requested folder name"
        )
