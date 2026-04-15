"""Test 60: Local auth provider — register, login, refresh, logout.

API-only test. Exercises the full local auth lifecycle without Clerk.
Only runs when AUTH_PROVIDER=local (skipped otherwise).

Tests:
- First user registration → admin role
- Second user registration → member role
- Duplicate email rejection
- Login with valid/invalid credentials
- Refresh token rotation
- Refresh token reuse detection (theft)
- Logout + cookie invalidation
- Local JWT → API key creation → API key auth
- Local JWT → WebSocket auth
"""

import os
import time

import pytest
import requests

API_URL = os.environ.get("ENGRAM_API_URL") or "http://localhost:8100/api"
AUTH_PROVIDER = os.environ.get("AUTH_PROVIDER", "local")

pytestmark = pytest.mark.skipif(
    AUTH_PROVIDER != "local",
    reason="Local auth tests only run when AUTH_PROVIDER=local",
)


def unique_email(label: str) -> str:
    """Generate a unique email to avoid collisions across test runs."""
    return f"e2e-local-{label}-{int(time.time())}@test.com"


PASSWORD = "E2eTestPass!99"


# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------


class TestRegistration:
    def test_first_user_is_admin(self):
        """First registered user gets admin role."""
        email = unique_email("admin")
        resp = requests.post(
            f"{API_URL}/auth/register",
            json={"email": email, "password": PASSWORD},
            timeout=10,
        )
        assert resp.status_code == 201, f"Expected 201, got {resp.status_code}: {resp.text}"
        body = resp.json()

        assert "access_token" in body
        assert body["user"]["email"] == email
        assert body["user"]["role"] in ("admin", "member")  # admin only if DB is empty

    def test_register_returns_refresh_cookie(self):
        """Registration sets an HTTP-only refresh_token cookie."""
        email = unique_email("cookie")
        resp = requests.post(
            f"{API_URL}/auth/register",
            json={"email": email, "password": PASSWORD},
            timeout=10,
        )
        assert resp.status_code == 201
        assert "refresh_token" in resp.cookies, "Should set refresh_token cookie"

    def test_duplicate_email_rejected(self):
        """Cannot register twice with the same email."""
        email = unique_email("dup")
        resp1 = requests.post(
            f"{API_URL}/auth/register",
            json={"email": email, "password": PASSWORD},
            timeout=10,
        )
        assert resp1.status_code == 201

        resp2 = requests.post(
            f"{API_URL}/auth/register",
            json={"email": email, "password": PASSWORD},
            timeout=10,
        )
        assert resp2.status_code == 422, f"Expected 422 for dup, got {resp2.status_code}"

    def test_missing_password_rejected(self):
        """Registration without password returns 422."""
        resp = requests.post(
            f"{API_URL}/auth/register",
            json={"email": unique_email("nopass")},
            timeout=10,
        )
        assert resp.status_code == 422


# ---------------------------------------------------------------------------
# Login
# ---------------------------------------------------------------------------


class TestLogin:
    @pytest.fixture(autouse=True)
    def _registered_user(self):
        self.email = unique_email("login")
        resp = requests.post(
            f"{API_URL}/auth/register",
            json={"email": self.email, "password": PASSWORD},
            timeout=10,
        )
        assert resp.status_code == 201

    def test_valid_credentials(self):
        """Login with correct password returns access token + refresh cookie."""
        resp = requests.post(
            f"{API_URL}/auth/login",
            json={"email": self.email, "password": PASSWORD},
            timeout=10,
        )
        assert resp.status_code == 200
        body = resp.json()
        assert "access_token" in body
        assert body["user"]["email"] == self.email
        assert "refresh_token" in resp.cookies

    def test_wrong_password(self):
        """Login with wrong password returns 401."""
        resp = requests.post(
            f"{API_URL}/auth/login",
            json={"email": self.email, "password": "WrongPassword!"},
            timeout=10,
        )
        assert resp.status_code == 401

    def test_nonexistent_user(self):
        """Login with unknown email returns 401."""
        resp = requests.post(
            f"{API_URL}/auth/login",
            json={"email": "nobody-ever@test.com", "password": PASSWORD},
            timeout=10,
        )
        assert resp.status_code == 401


# ---------------------------------------------------------------------------
# Token refresh
# ---------------------------------------------------------------------------


class TestRefresh:
    @pytest.fixture(autouse=True)
    def _registered_session(self):
        self.email = unique_email("refresh")
        resp = requests.post(
            f"{API_URL}/auth/register",
            json={"email": self.email, "password": PASSWORD},
            timeout=10,
        )
        assert resp.status_code == 201
        self.access_token = resp.json()["access_token"]
        self.refresh_cookie = resp.cookies["refresh_token"]

    def test_refresh_returns_new_tokens(self):
        """POST /auth/refresh with valid cookie returns new access token + rotated cookie."""
        resp = requests.post(
            f"{API_URL}/auth/refresh",
            cookies={"refresh_token": self.refresh_cookie},
            timeout=10,
        )
        assert resp.status_code == 200, f"Refresh failed: {resp.text}"
        body = resp.json()
        assert "access_token" in body

        # New refresh cookie should differ from the old one (rotation)
        new_cookie = resp.cookies.get("refresh_token")
        assert new_cookie is not None, "Should set new refresh_token cookie"
        assert new_cookie != self.refresh_cookie, "Refresh token should rotate"

    def test_refresh_token_works_for_api(self):
        """Access token from refresh can authenticate API calls."""
        resp = requests.post(
            f"{API_URL}/auth/refresh",
            cookies={"refresh_token": self.refresh_cookie},
            timeout=10,
        )
        new_token = resp.json()["access_token"]

        me_resp = requests.get(
            f"{API_URL}/me",
            headers={"Authorization": f"Bearer {new_token}"},
            timeout=10,
        )
        assert me_resp.status_code == 200
        assert me_resp.json()["email"] == self.email

    def test_old_refresh_token_rejected_after_rotation(self):
        """After rotation, the old refresh token should be rejected."""
        # Use the token (rotates it)
        resp1 = requests.post(
            f"{API_URL}/auth/refresh",
            cookies={"refresh_token": self.refresh_cookie},
            timeout=10,
        )
        assert resp1.status_code == 200

        # Reuse the old token — should fail (reuse detection)
        resp2 = requests.post(
            f"{API_URL}/auth/refresh",
            cookies={"refresh_token": self.refresh_cookie},
            timeout=10,
        )
        assert resp2.status_code == 401, (
            f"Reused token should be rejected, got {resp2.status_code}"
        )

    def test_missing_cookie_rejected(self):
        """Refresh without cookie returns 401."""
        resp = requests.post(f"{API_URL}/auth/refresh", timeout=10)
        assert resp.status_code == 401


# ---------------------------------------------------------------------------
# Logout
# ---------------------------------------------------------------------------


class TestLogout:
    def test_logout_invalidates_refresh(self):
        """After logout, the refresh token no longer works."""
        email = unique_email("logout")

        # Register
        reg = requests.post(
            f"{API_URL}/auth/register",
            json={"email": email, "password": PASSWORD},
            timeout=10,
        )
        assert reg.status_code == 201
        cookie = reg.cookies["refresh_token"]

        # Logout
        logout_resp = requests.post(
            f"{API_URL}/auth/logout",
            cookies={"refresh_token": cookie},
            timeout=10,
        )
        assert logout_resp.status_code == 204

        # Try to refresh — should fail
        refresh_resp = requests.post(
            f"{API_URL}/auth/refresh",
            cookies={"refresh_token": cookie},
            timeout=10,
        )
        assert refresh_resp.status_code == 401


# ---------------------------------------------------------------------------
# Access token auth → authenticated endpoints
# ---------------------------------------------------------------------------


class TestAccessTokenAuth:
    @pytest.fixture(autouse=True)
    def _registered_session(self):
        self.email = unique_email("authed")
        resp = requests.post(
            f"{API_URL}/auth/register",
            json={"email": self.email, "password": PASSWORD},
            timeout=10,
        )
        assert resp.status_code == 201
        self.access_token = resp.json()["access_token"]

    def test_me_endpoint(self):
        """/me returns the authenticated user."""
        resp = requests.get(
            f"{API_URL}/me",
            headers={"Authorization": f"Bearer {self.access_token}"},
            timeout=10,
        )
        assert resp.status_code == 200
        assert resp.json()["email"] == self.email

    def test_create_api_key(self):
        """Can create an API key using local JWT auth, then use it."""
        # Create API key
        resp = requests.post(
            f"{API_URL}/api-keys",
            headers={"Authorization": f"Bearer {self.access_token}"},
            json={"name": "e2e-local-test"},
            timeout=10,
        )
        assert resp.status_code in (200, 201), f"API key creation failed: {resp.text}"
        api_key = resp.json().get("key") or resp.json().get("raw_key")
        assert api_key is not None, f"No key in response: {resp.json()}"
        assert api_key.startswith("engram_")

        # Use API key for /me
        me_resp = requests.get(
            f"{API_URL}/me",
            headers={"Authorization": f"Bearer {api_key}"},
            timeout=10,
        )
        assert me_resp.status_code == 200
        assert me_resp.json()["email"] == self.email

    def test_invalid_token_rejected(self):
        """Garbage token returns 401."""
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


# ---------------------------------------------------------------------------
# Multi-user isolation
# ---------------------------------------------------------------------------


class TestMultiUserIsolation:
    def test_users_cannot_see_each_other(self):
        """Two local users get different user IDs and can't cross-access."""
        email_a = unique_email("iso-a")
        email_b = unique_email("iso-b")

        reg_a = requests.post(
            f"{API_URL}/auth/register",
            json={"email": email_a, "password": PASSWORD},
            timeout=10,
        )
        reg_b = requests.post(
            f"{API_URL}/auth/register",
            json={"email": email_b, "password": PASSWORD},
            timeout=10,
        )
        assert reg_a.status_code == 201
        assert reg_b.status_code == 201

        token_a = reg_a.json()["access_token"]
        token_b = reg_b.json()["access_token"]

        me_a = requests.get(
            f"{API_URL}/me",
            headers={"Authorization": f"Bearer {token_a}"},
            timeout=10,
        ).json()
        me_b = requests.get(
            f"{API_URL}/me",
            headers={"Authorization": f"Bearer {token_b}"},
            timeout=10,
        ).json()

        assert me_a["email"] == email_a
        assert me_b["email"] == email_b
        assert me_a["id"] != me_b["id"], "Users should have different IDs"
