"""Test 61: Provider-agnostic auth tests.

These tests run regardless of AUTH_PROVIDER. They verify behavior
that should work identically with Clerk or local auth:
- /me endpoint returns user info
- API key creation and usage
- Invalid/missing tokens rejected
- Multi-user isolation via /me
"""

import os

import pytest
import requests

API_URL = os.environ.get("ENGRAM_API_URL") or "http://localhost:8100/api"


class TestMeEndpoint:
    """GET /me works with any auth provider's API key."""

    def test_me_returns_user(self, api_sync, sync_user):
        """/me returns the authenticated user's email."""
        resp = api_sync.session.get(f"{API_URL}/me", timeout=10)
        assert resp.status_code == 200
        assert resp.json()["user"]["email"] == sync_user[0]

    def test_me_different_users(self, api_sync, api_iso, sync_user, isolation_user):
        """Two users see their own data via /me."""
        me_sync = api_sync.session.get(f"{API_URL}/me", timeout=10).json()
        me_iso = api_iso.session.get(f"{API_URL}/me", timeout=10).json()

        assert me_sync["user"]["email"] == sync_user[0]
        assert me_iso["user"]["email"] == isolation_user[0]
        assert me_sync["user"]["id"] != me_iso["user"]["id"]


class TestApiKeyAuth:
    """API key creation and usage — works with any auth provider."""

    def test_create_and_use_api_key(self, api_sync, sync_user):
        """Create an API key, then use it to authenticate."""
        # Create API key
        resp = api_sync.session.post(
            f"{API_URL}/api-keys",
            json={"name": "e2e-agnostic-test"},
            timeout=10,
        )
        assert resp.status_code == 200, f"API key creation failed: {resp.text}"
        api_key = resp.json().get("key")
        assert api_key is not None
        assert api_key.startswith("engram_")

        # Use the new API key for /me
        me_resp = requests.get(
            f"{API_URL}/me",
            headers={"Authorization": f"Bearer {api_key}"},
            timeout=10,
        )
        assert me_resp.status_code == 200
        assert me_resp.json()["user"]["email"] == sync_user[0]


class TestTokenRejection:
    """Invalid/missing auth rejected — universal, no fixtures needed."""

    def test_invalid_token_rejected(self):
        """Garbage bearer token returns 401."""
        resp = requests.get(
            f"{API_URL}/me",
            headers={"Authorization": "Bearer not.a.real.jwt"},
            timeout=10,
        )
        assert resp.status_code == 401

    def test_no_auth_rejected(self):
        """Request without auth header returns 401."""
        resp = requests.get(f"{API_URL}/me", timeout=10)
        assert resp.status_code == 401
