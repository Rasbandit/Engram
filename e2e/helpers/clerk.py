"""Clerk Backend API client for E2E test user management.

Used to clean up test users created during Playwright browser tests.
Requires CLERK_SECRET_KEY (sk_test_...) from environment.

Clerk Backend API docs: https://clerk.com/docs/reference/backend-api
"""

from __future__ import annotations

import logging
import time

import requests

logger = logging.getLogger(__name__)

# Clerk's POST /sessions endpoint exhibits eventual-consistency 404s vs the
# user store: a user_id that GET /users/{id} returns happily can still
# 404 from POST /sessions for a few hundred ms after creation. Retry
# resource_not_found errors with exponential backoff. 5 attempts span
# ~6s total, well above Clerk's observed lag window (<1s in practice).
_SESSION_CREATE_MAX_ATTEMPTS = 5
_SESSION_CREATE_INITIAL_BACKOFF = 0.2


class ClerkClient:
    """Clerk Backend API client for E2E test user lifecycle.

    Supports creating users, obtaining session tokens, and cleanup —
    all via the Backend API, no browser needed.
    """

    def __init__(self, secret_key: str):
        self.session = requests.Session()
        self.session.headers["Authorization"] = f"Bearer {secret_key}"
        self.session.headers["Content-Type"] = "application/json"
        self.base_url = "https://api.clerk.dev/v1"

    def find_user_by_email(self, email: str) -> str | None:
        """Find a Clerk user ID by email address. Returns user_id or None."""
        resp = self.session.get(
            f"{self.base_url}/users",
            params={"email_address": email},
            timeout=10,
        )
        resp.raise_for_status()
        users = resp.json()
        if not users:
            return None
        return users[0]["id"]

    def create_user(self, email: str, password: str) -> str:
        """Create a Clerk user via Backend API. Returns user_id.

        Idempotent: if Clerk reports the email as already taken (422
        form_identifier_exists), returns the existing user's ID rather
        than raising. Handles the common case where a prior fixture
        created the user but a downstream step (API key creation,
        network hiccup) failed mid-setup, causing pytest-rerunfailures
        to re-invoke provision_user with the same email.
        """
        username = email.split("@")[0]
        resp = self.session.post(
            f"{self.base_url}/users",
            json={
                "email_address": [email],
                "username": username,
                "password": password,
                "skip_password_checks": True,
            },
            timeout=10,
        )
        if resp.status_code == 422 and self._is_identifier_taken(resp):
            existing_id = self.find_user_by_email(email)
            if existing_id:
                logger.warning(
                    "Clerk user %s already exists for %s — reusing", existing_id, email
                )
                return existing_id
            logger.error(
                "Clerk says %s is taken but lookup found nothing: %s",
                email, resp.text,
            )
        if not resp.ok:
            logger.error("Clerk create_user failed for %s: %s %s", email, resp.status_code, resp.text)
        resp.raise_for_status()
        user_id = resp.json()["id"]
        logger.info("Created Clerk user %s (%s)", user_id, email)
        return user_id

    @staticmethod
    def _is_identifier_taken(resp: requests.Response) -> bool:
        try:
            errors = resp.json().get("errors", [])
        except ValueError:
            return False
        return any(e.get("code") == "form_identifier_exists" for e in errors)

    def create_session_token(self, user_id: str) -> str:
        """Create a session for a user and return a short-lived JWT.

        Uses Clerk's Backend API to create a session, then mints a
        session token (valid ~60s). This JWT can be used as a Bearer
        token or injected as Clerk's __session cookie.

        Retries POST /sessions on transient 404 resource_not_found
        (Clerk eventual-consistency lag between user create/lookup and
        session endpoint visibility). See `_create_session_with_retry`.
        """
        session_id = self._create_session_with_retry(user_id)

        # Mint session token (no retry needed — session is fresh)
        resp = self.session.post(
            f"{self.base_url}/sessions/{session_id}/tokens",
            timeout=10,
        )
        if not resp.ok:
            logger.error("Clerk create_token failed: %s %s", resp.status_code, resp.text)
        resp.raise_for_status()
        token = resp.json()["jwt"]
        logger.info("Created session token for user %s (session %s)", user_id, session_id)
        return token

    def _create_session_with_retry(self, user_id: str) -> str:
        """POST /sessions with exponential-backoff retry on 404 resource_not_found.

        Returns the session_id. Raises on non-404 errors immediately, or after
        exhausting retries on persistent 404.
        """
        backoff = _SESSION_CREATE_INITIAL_BACKOFF
        last_resp: requests.Response | None = None
        for attempt in range(1, _SESSION_CREATE_MAX_ATTEMPTS + 1):
            resp = self.session.post(
                f"{self.base_url}/sessions",
                json={"user_id": user_id},
                timeout=10,
            )
            last_resp = resp
            if resp.ok:
                return resp.json()["id"]
            if resp.status_code == 404 and self._is_resource_not_found(resp):
                if attempt < _SESSION_CREATE_MAX_ATTEMPTS:
                    logger.warning(
                        "Clerk create_session 404 for user %s (attempt %d/%d, sleeping %.2fs)",
                        user_id, attempt, _SESSION_CREATE_MAX_ATTEMPTS, backoff,
                    )
                    time.sleep(backoff)
                    backoff *= 2
                    continue
                logger.error(
                    "Clerk create_session 404 for user %s exhausted %d retries: %s",
                    user_id, _SESSION_CREATE_MAX_ATTEMPTS, resp.text,
                )
            else:
                logger.error("Clerk create_session failed: %s %s", resp.status_code, resp.text)
            resp.raise_for_status()
        # Defensive — raise_for_status above should always raise on the final attempt.
        assert last_resp is not None
        last_resp.raise_for_status()
        raise RuntimeError("unreachable")  # pragma: no cover

    @staticmethod
    def _is_resource_not_found(resp: requests.Response) -> bool:
        try:
            errors = resp.json().get("errors", [])
        except ValueError:
            return False
        return any(e.get("code") == "resource_not_found" for e in errors)

    def get_testing_token(self) -> str:
        """Get a Testing Token to bypass bot detection in Clerk's Frontend API."""
        resp = self.session.post(
            f"{self.base_url}/testing_tokens",
            timeout=10,
        )
        resp.raise_for_status()
        return resp.json()["token"]

    def delete_user(self, user_id: str) -> None:
        """Delete a Clerk user by ID."""
        resp = self.session.delete(
            f"{self.base_url}/users/{user_id}",
            timeout=10,
        )
        if resp.status_code == 404:
            logger.warning("Clerk user %s already deleted", user_id)
            return
        resp.raise_for_status()
        logger.info("Deleted Clerk user %s", user_id)

    def list_users(self, limit: int = 100, offset: int = 0) -> list[dict]:
        """List Clerk users with pagination."""
        resp = self.session.get(
            f"{self.base_url}/users",
            params={"limit": limit, "offset": offset, "order_by": "created_at"},
            timeout=15,
        )
        resp.raise_for_status()
        return resp.json()

    def cleanup_user(self, email: str) -> None:
        """Find and delete a user by email. No-op if not found."""
        user_id = self.find_user_by_email(email)
        if user_id:
            self.delete_user(user_id)
        else:
            logger.info("No Clerk user found for %s — skipping cleanup", email)
