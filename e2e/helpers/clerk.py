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
    """Minimal Clerk Backend API client for finding and deleting test users."""

    def __init__(self, secret_key: str):
        self.session = requests.Session()
        self.session.headers["Authorization"] = f"Bearer {secret_key}"
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
