"""Clerk Backend API client for E2E test user management.

Used to clean up test users created during Playwright browser tests.
Requires CLERK_SECRET_KEY (sk_test_...) from environment.

Clerk Backend API docs: https://clerk.com/docs/reference/backend-api
"""

from __future__ import annotations

import logging

import requests

logger = logging.getLogger(__name__)


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
        """Create a Clerk user via Backend API. Returns user_id."""
        # Derive a username from the email (Clerk instance may require it)
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
        if not resp.ok:
            logger.error("Clerk create_user failed: %s %s", resp.status_code, resp.text)
        resp.raise_for_status()
        user_id = resp.json()["id"]
        logger.info("Created Clerk user %s (%s)", user_id, email)
        return user_id

    def create_session_token(self, user_id: str) -> str:
        """Create a session for a user and return a short-lived JWT.

        Uses Clerk's Backend API to create a session, then mints a
        session token (valid ~60s). This JWT can be used as a Bearer
        token or injected as Clerk's __session cookie.
        """
        # Create session
        resp = self.session.post(
            f"{self.base_url}/sessions",
            json={"user_id": user_id},
            timeout=10,
        )
        if not resp.ok:
            logger.error("Clerk create_session failed: %s %s", resp.status_code, resp.text)
        resp.raise_for_status()
        session_id = resp.json()["id"]

        # Mint session token
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

    def cleanup_user(self, email: str) -> None:
        """Find and delete a user by email. No-op if not found."""
        user_id = self.find_user_by_email(email)
        if user_id:
            self.delete_user(user_id)
        else:
            logger.info("No Clerk user found for %s — skipping cleanup", email)
