"""Backend REST API client for E2E tests."""

from __future__ import annotations

import logging
import re
import time
from urllib.parse import quote

import requests

logger = logging.getLogger(__name__)


class ApiClient:
    """Thin wrapper around the Engram REST API."""

    def __init__(self, base_url: str, api_key: str):
        self.base_url = base_url.rstrip("/")
        self.session = requests.Session()
        self.session.headers["Authorization"] = f"Bearer {api_key}"

    def ping(self) -> bool:
        """GET /folders — returns True if auth works."""
        resp = self.session.get(f"{self.base_url}/folders", timeout=10)
        return resp.status_code == 200

    def get_note(self, path: str) -> dict | None:
        """GET /notes/{path}. Returns parsed JSON or None on 404."""
        resp = self.session.get(
            f"{self.base_url}/notes/{quote(path, safe='')}", timeout=10
        )
        if resp.status_code == 404:
            return None
        resp.raise_for_status()
        return resp.json()

    def create_note(
        self, path: str, content: str, mtime: float | None = None
    ) -> dict:
        """POST /notes — upsert a note."""
        payload: dict = {
            "path": path,
            "content": content,
            "mtime": mtime if mtime is not None else time.time(),
        }
        resp = self.session.post(
            f"{self.base_url}/notes", json=payload, timeout=10
        )
        resp.raise_for_status()
        return resp.json()

    def delete_note(self, path: str) -> int:
        """DELETE /notes/{path}. Returns HTTP status code."""
        resp = self.session.delete(
            f"{self.base_url}/notes/{quote(path, safe='')}", timeout=10
        )
        return resp.status_code

    def get_changes(self, since: str) -> dict:
        """GET /notes/changes?since=..."""
        resp = self.session.get(
            f"{self.base_url}/notes/changes",
            params={"since": since},
            timeout=10,
        )
        resp.raise_for_status()
        return resp.json()

    def wait_for_note(
        self, path: str, timeout: float = 10, poll: float = 0.5
    ) -> dict:
        """Poll until note exists on server. Returns the note dict."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            note = self.get_note(path)
            if note is not None:
                return note
            time.sleep(poll)
        raise TimeoutError(f"Note {path} not on server after {timeout}s")

    def wait_for_note_content(
        self, path: str, expected: str, timeout: float = 10, poll: float = 0.5
    ) -> dict:
        """Poll until note on server contains expected substring."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            note = self.get_note(path)
            if note is not None and expected in note.get("content", ""):
                return note
            time.sleep(poll)
        raise TimeoutError(
            f"Note {path} did not contain '{expected}' on server after {timeout}s"
        )

    def wait_for_note_gone(
        self, path: str, timeout: float = 10, poll: float = 0.5
    ) -> None:
        """Poll until note returns 404 on server."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            note = self.get_note(path)
            if note is None:
                return
            time.sleep(poll)
        raise TimeoutError(f"Note {path} still on server after {timeout}s")

    def rename_note(self, old_path: str, new_path: str) -> int:
        """POST /notes/rename. Returns HTTP status code."""
        resp = self.session.post(
            f"{self.base_url}/notes/rename",
            json={"old_path": old_path, "new_path": new_path},
            timeout=10,
        )
        return resp.status_code

    def append_note(self, path: str, text: str) -> int:
        """POST /notes/append. Returns HTTP status code."""
        resp = self.session.post(
            f"{self.base_url}/notes/append",
            json={"path": path, "text": text},
            timeout=10,
        )
        return resp.status_code

    def upload_attachment(self, path: str, data: bytes) -> int:
        """POST /attachments. Returns HTTP status code."""
        import base64
        resp = self.session.post(
            f"{self.base_url}/attachments",
            json={
                "path": path,
                "content_base64": base64.b64encode(data).decode(),
                "mtime": time.time(),
            },
            timeout=10,
        )
        return resp.status_code

    def get_attachment(self, path: str) -> requests.Response:
        """GET /attachments/{path}. Returns full response."""
        return self.session.get(
            f"{self.base_url}/attachments/{quote(path, safe='')}",
            timeout=10,
        )

    def delete_attachment(self, path: str) -> int:
        """DELETE /attachments/{path}. Returns HTTP status code."""
        resp = self.session.delete(
            f"{self.base_url}/attachments/{quote(path, safe='')}",
            timeout=10,
        )
        return resp.status_code

    def rename_folder(self, old_folder: str, new_folder: str) -> int:
        """POST /folders/rename. Returns HTTP status code."""
        resp = self.session.post(
            f"{self.base_url}/folders/rename",
            json={"old_folder": old_folder, "new_folder": new_folder},
            timeout=10,
        )
        return resp.status_code

    def get_manifest(self) -> dict:
        """GET /sync/manifest. Returns manifest dict."""
        resp = self.session.get(f"{self.base_url}/sync/manifest", timeout=10)
        resp.raise_for_status()
        return resp.json()

    def ingest_logs(self, entries: list[dict]) -> int:
        """POST /logs. Returns HTTP status code."""
        resp = self.session.post(
            f"{self.base_url}/logs",
            json={"entries": entries},
            timeout=10,
        )
        return resp.status_code

    def get_logs(self, level: str = "", since: str = "", limit: int = 200) -> dict:
        """GET /logs. Returns logs dict."""
        params = {"limit": limit}
        if level:
            params["level"] = level
        if since:
            params["since"] = since
        resp = self.session.get(
            f"{self.base_url}/logs", params=params, timeout=10
        )
        resp.raise_for_status()
        return resp.json()

    def list_folder(self, folder: str = "") -> dict:
        """GET /folders/list. Returns folder listing dict."""
        resp = self.session.get(
            f"{self.base_url}/folders/list",
            params={"folder": folder},
            timeout=10,
        )
        resp.raise_for_status()
        return resp.json()

    def get_folders(self) -> list:
        """GET /folders."""
        resp = self.session.get(f"{self.base_url}/folders", timeout=10)
        resp.raise_for_status()
        return resp.json().get("folders", [])


def register_user(base_url: str, email: str, password: str) -> str:
    """Register a user, log in, create an API key, and return the key string.

    Follows the same pattern as backend/test_plan.sh:
    1. POST /register (form data) → 303 redirect
    2. POST /login (form data) → session cookie
    3. POST /settings/keys → extract engram_... key from HTML
    """
    base = base_url.rstrip("/")
    s = requests.Session()

    # Register
    resp = s.post(
        f"{base}/register",
        data={"email": email, "password": password, "display_name": f"E2E {email}"},
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        allow_redirects=False,
        timeout=10,
    )
    if resp.status_code not in (303, 400):
        raise RuntimeError(f"Registration failed: HTTP {resp.status_code}")

    # Login (in case registration redirected without setting cookie properly)
    resp = s.post(
        f"{base}/login",
        data={"email": email, "password": password},
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        allow_redirects=True,
        timeout=10,
    )

    # Create API key
    resp = s.post(
        f"{base}/settings/keys",
        data={"name": "e2e-test-key"},
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        allow_redirects=True,
        timeout=10,
    )
    if resp.status_code != 200:
        raise RuntimeError(
            f"API key creation failed: HTTP {resp.status_code}\n{resp.text[:500]}"
        )

    # Extract API key from HTML response (pattern: engram_<alphanum>)
    match = re.search(r"engram_[A-Za-z0-9_-]+", resp.text)
    if not match:
        raise RuntimeError(
            f"Could not extract API key from response:\n{resp.text[:500]}"
        )

    api_key = match.group(0)
    logger.info("Registered user %s, API key: %s...", email, api_key[:20])
    return api_key
