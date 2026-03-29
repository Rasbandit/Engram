"""Unit tests for auth.py — JWT creation/validation, API key + session dependencies."""

from __future__ import annotations

import sys
import time
from datetime import datetime, timedelta, timezone
from unittest.mock import MagicMock, patch

import pytest

# Stub heavy dependencies before importing auth
sys.modules.setdefault("psycopg", MagicMock())
sys.modules.setdefault("psycopg.errors", MagicMock())
sys.modules.setdefault("pool", MagicMock())
sys.modules.setdefault("redis_client", MagicMock(is_enabled=MagicMock(return_value=False)))

# Set JWT_SECRET before importing auth (config reads env at import time)
import os

os.environ.setdefault("JWT_SECRET", "test-secret-key-for-unit-tests")

from jose import jwt as jose_jwt

import auth
import db


# ---------------------------------------------------------------------------
# create_jwt
# ---------------------------------------------------------------------------


class TestCreateJWT:
    def test_returns_string(self):
        token = auth.create_jwt(42)
        assert isinstance(token, str)

    def test_contains_sub_claim(self):
        token = auth.create_jwt(42)
        payload = jose_jwt.decode(token, "test-secret-key-for-unit-tests", algorithms=["HS256"])
        assert payload["sub"] == "42"

    def test_sub_is_string_of_user_id(self):
        token = auth.create_jwt(999)
        payload = jose_jwt.decode(token, "test-secret-key-for-unit-tests", algorithms=["HS256"])
        assert payload["sub"] == "999"

    def test_has_expiry(self):
        token = auth.create_jwt(1)
        payload = jose_jwt.decode(token, "test-secret-key-for-unit-tests", algorithms=["HS256"])
        assert "exp" in payload

    def test_expiry_is_7_days(self):
        token = auth.create_jwt(1)
        payload = jose_jwt.decode(token, "test-secret-key-for-unit-tests", algorithms=["HS256"])
        exp = datetime.fromtimestamp(payload["exp"], tz=timezone.utc)
        expected = datetime.now(timezone.utc) + timedelta(days=7)
        # JWT exp is integer seconds, so allow 2s tolerance
        assert abs((exp - expected).total_seconds()) < 2

    def test_signed_with_hs256(self):
        token = auth.create_jwt(1)
        header = jose_jwt.get_unverified_header(token)
        assert header["alg"] == "HS256"

    def test_invalid_secret_rejects(self):
        token = auth.create_jwt(1)
        with pytest.raises(Exception):
            jose_jwt.decode(token, "wrong-secret", algorithms=["HS256"])


# ---------------------------------------------------------------------------
# get_current_user_api_key
# ---------------------------------------------------------------------------


class TestGetCurrentUserApiKey:
    def test_valid_key_returns_user(self):
        user = {"id": 1, "email": "a@b.com", "display_name": "A"}
        creds = MagicMock()
        creds.credentials = "engram_validkey"
        with patch.object(db, "validate_api_key", return_value=user):
            result = auth.get_current_user_api_key(credentials=creds)
        assert result == user

    def test_invalid_key_raises_401(self):
        creds = MagicMock()
        creds.credentials = "engram_badkey"
        with patch.object(db, "validate_api_key", return_value=None):
            with pytest.raises(Exception) as exc_info:
                auth.get_current_user_api_key(credentials=creds)
            assert exc_info.value.status_code == 401
            assert "Invalid API key" in exc_info.value.detail

    def test_passes_raw_key_to_validate(self):
        creds = MagicMock()
        creds.credentials = "engram_mykey123"
        with patch.object(db, "validate_api_key", return_value=None) as mock_validate:
            with pytest.raises(Exception):
                auth.get_current_user_api_key(credentials=creds)
        mock_validate.assert_called_once_with("engram_mykey123")


# ---------------------------------------------------------------------------
# get_current_user_session
# ---------------------------------------------------------------------------


class TestGetCurrentUserSession:
    def _make_request(self, cookies: dict | None = None):
        req = MagicMock()
        req.cookies = cookies or {}
        return req

    def test_missing_cookie_redirects_to_login(self):
        req = self._make_request({})
        with pytest.raises(Exception) as exc_info:
            auth.get_current_user_session(req)
        assert exc_info.value.status_code == 303
        assert exc_info.value.headers["Location"] == "/login"

    def test_valid_token_returns_user(self):
        user = {"id": 5, "email": "x@y.com", "display_name": "X"}
        token = auth.create_jwt(5)
        req = self._make_request({"engram_session": token})
        with patch.object(db, "get_user_by_id", return_value=user):
            result = auth.get_current_user_session(req)
        assert result == user

    def test_expired_token_redirects(self):
        # Create a token that's already expired
        payload = {
            "sub": "1",
            "exp": datetime.now(timezone.utc) - timedelta(hours=1),
        }
        token = jose_jwt.encode(payload, "test-secret-key-for-unit-tests", algorithm="HS256")
        req = self._make_request({"engram_session": token})
        with pytest.raises(Exception) as exc_info:
            auth.get_current_user_session(req)
        assert exc_info.value.status_code == 303

    def test_tampered_token_redirects(self):
        token = auth.create_jwt(1)
        # Corrupt the signature
        tampered = token[:-5] + "XXXXX"
        req = self._make_request({"engram_session": tampered})
        with pytest.raises(Exception) as exc_info:
            auth.get_current_user_session(req)
        assert exc_info.value.status_code == 303

    def test_wrong_secret_token_redirects(self):
        payload = {"sub": "1", "exp": datetime.now(timezone.utc) + timedelta(days=1)}
        token = jose_jwt.encode(payload, "different-secret", algorithm="HS256")
        req = self._make_request({"engram_session": token})
        with pytest.raises(Exception) as exc_info:
            auth.get_current_user_session(req)
        assert exc_info.value.status_code == 303

    def test_missing_sub_claim_redirects(self):
        payload = {"exp": datetime.now(timezone.utc) + timedelta(days=1)}
        token = jose_jwt.encode(payload, "test-secret-key-for-unit-tests", algorithm="HS256")
        req = self._make_request({"engram_session": token})
        with pytest.raises(Exception) as exc_info:
            auth.get_current_user_session(req)
        assert exc_info.value.status_code == 303

    def test_nonexistent_user_redirects(self):
        token = auth.create_jwt(9999)
        req = self._make_request({"engram_session": token})
        with patch.object(db, "get_user_by_id", return_value=None):
            with pytest.raises(Exception) as exc_info:
                auth.get_current_user_session(req)
        assert exc_info.value.status_code == 303

    def test_non_integer_sub_redirects(self):
        payload = {
            "sub": "not-a-number",
            "exp": datetime.now(timezone.utc) + timedelta(days=1),
        }
        token = jose_jwt.encode(payload, "test-secret-key-for-unit-tests", algorithm="HS256")
        req = self._make_request({"engram_session": token})
        with pytest.raises(Exception) as exc_info:
            auth.get_current_user_session(req)
        assert exc_info.value.status_code == 303
