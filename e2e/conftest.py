"""Pytest fixtures for Engram E2E tests.

Three Obsidian instances:
- A + B: same user (sync pair — proves two-machine sync)
- C: different user (proves multi-tenant isolation)

Auth is provider-agnostic: AuthProvider abstracts Clerk vs local
registration. All downstream fixtures receive an API key regardless
of which provider bootstrapped the user.

All fixtures are session-scoped because Obsidian startup takes ~30s (AppImage
extraction + plugin load). Each test uses unique file paths to avoid
cross-test interference. Per-test vault cleanup is avoided because deleting
files triggers the plugin's file watcher, causing unexpected sync events.
"""

from __future__ import annotations

import logging
import os
import secrets
from datetime import datetime
from pathlib import Path

import pytest

from helpers.api import ApiClient
from helpers.auth_provider import get_auth_provider, ClerkAuthProvider
from helpers.cdp import CdpClient
from helpers.cleanup import cleanup_test_data, cleanup_vaults
from helpers.obsidian import ObsidianInstance


logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")

API_URL = os.environ.get("ENGRAM_API_URL") or "http://localhost:8100/api"
PLUGIN_SRC = Path(os.environ.get("ENGRAM_PLUGIN_SRC", Path(__file__).parent.parent / "plugin"))
OBSIDIAN_BIN = Path.home() / "Applications" / "Obsidian.AppImage"

# Dynamic ports/paths for parallel CI runs (defaults match legacy hardcoded values)
VAULT_PREFIX = os.environ.get("E2E_VAULT_PREFIX", "/tmp/e2e-vault")
CONFIG_PREFIX = os.environ.get("E2E_CONFIG_PREFIX", "/tmp/e2e-obsidian-config")
CDP_PORT_A = int(os.environ.get("E2E_CDP_PORT_A") or "9250")
CDP_PORT_B = int(os.environ.get("E2E_CDP_PORT_B") or "9251")
CDP_PORT_C = int(os.environ.get("E2E_CDP_PORT_C") or "9252")
DISPLAY_BASE = int(os.environ.get("E2E_DISPLAY_BASE") or "99")


# ---------------------------------------------------------------------------
# Unique timestamp for this test run
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def ts():
    return datetime.now().strftime("%Y%m%d%H%M%S%f")


# ---------------------------------------------------------------------------
# Auth provider (unified — works with both Clerk and local)
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def auth_provider():
    """Unified auth provider based on AUTH_PROVIDER env var."""
    provider = get_auth_provider(API_URL)
    provider.cleanup_all_e2e_users()
    return provider


@pytest.fixture(scope="session")
def clerk_client(auth_provider):
    """Clerk Backend API client — only available when AUTH_PROVIDER=clerk.

    Used by Clerk-specific tests (OAuth device flow, cross-auth sync).
    Returns None when running with local auth.
    """
    if isinstance(auth_provider, ClerkAuthProvider):
        return auth_provider.clerk_client
    return None


# ---------------------------------------------------------------------------
# Users (provider-agnostic)
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def sync_user(ts, auth_provider):
    """Shared user for Obsidian A + B.

    Returns: (email, provider_user_id, api_key)
    """
    email = f"e2e-sync-{ts}@example.com"
    password = secrets.token_urlsafe(32)
    provider_user_id, api_key = auth_provider.provision_user(email, password)
    return email, provider_user_id, api_key


@pytest.fixture(scope="session")
def isolation_user(ts, auth_provider):
    """Separate user for Obsidian C (multi-tenant isolation).

    Returns: (email, provider_user_id, api_key)
    """
    email = f"e2e-iso-{ts}@example.com"
    password = secrets.token_urlsafe(32)
    provider_user_id, api_key = auth_provider.provision_user(email, password)
    return email, provider_user_id, api_key


# ---------------------------------------------------------------------------
# Obsidian instances
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def sync_client_id(ts):
    """Shared client_id so A and B register the same server vault."""
    return f"e2e-sync-pair-{ts}"


@pytest.fixture(scope="session")
def obsidian_a(sync_user, sync_client_id):

    inst = ObsidianInstance(
        name="A",
        vault_path=Path(f"{VAULT_PREFIX}-a"),
        cdp_port=CDP_PORT_A,
        display=f":{DISPLAY_BASE}",
        api_url=API_URL,
        api_key=sync_user[2],
        plugin_src=PLUGIN_SRC,
        obsidian_bin=OBSIDIAN_BIN,
        client_id=sync_client_id,
        config_dir=Path(f"{CONFIG_PREFIX}-a"),
    )
    inst.start()
    yield inst
    inst.stop()


@pytest.fixture(scope="session")
def obsidian_b(sync_user, sync_client_id):
    """Same user as A — proves two-machine sync."""

    inst = ObsidianInstance(
        name="B",
        vault_path=Path(f"{VAULT_PREFIX}-b"),
        cdp_port=CDP_PORT_B,
        display=f":{DISPLAY_BASE - 1}",
        api_url=API_URL,
        api_key=sync_user[2],
        plugin_src=PLUGIN_SRC,
        obsidian_bin=OBSIDIAN_BIN,
        client_id=sync_client_id,
        config_dir=Path(f"{CONFIG_PREFIX}-b"),
    )
    inst.start()
    yield inst
    inst.stop()


@pytest.fixture(scope="session")
def obsidian_c(isolation_user):
    """Different user — proves multi-tenant isolation."""

    inst = ObsidianInstance(
        name="C",
        vault_path=Path(f"{VAULT_PREFIX}-c"),
        cdp_port=CDP_PORT_C,
        display=f":{DISPLAY_BASE - 2}",
        api_url=API_URL,
        api_key=isolation_user[2],
        plugin_src=PLUGIN_SRC,
        obsidian_bin=OBSIDIAN_BIN,
        config_dir=Path(f"{CONFIG_PREFIX}-c"),
    )
    inst.start()
    yield inst
    inst.stop()


# ---------------------------------------------------------------------------
# CDP clients
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def cdp_a(obsidian_a):
    return CdpClient(port=obsidian_a.cdp_port)


@pytest.fixture(scope="session")
def cdp_b(obsidian_b):
    return CdpClient(port=obsidian_b.cdp_port)


@pytest.fixture(scope="session")
def cdp_c(obsidian_c):
    return CdpClient(port=obsidian_c.cdp_port)


# ---------------------------------------------------------------------------
# API clients (always use API key — works with any auth provider)
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def api_sync(sync_user):
    """API client for sync user. Uses API key (provider-agnostic)."""
    return ApiClient(API_URL, sync_user[2])


@pytest.fixture(scope="session")
def api_iso(isolation_user):
    """API client for isolation user. Uses API key (provider-agnostic)."""
    return ApiClient(API_URL, isolation_user[2])


# ---------------------------------------------------------------------------
# Vault paths (convenience)
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def vault_a(obsidian_a):
    return obsidian_a.vault_path


@pytest.fixture(scope="session")
def vault_b(obsidian_b):
    return obsidian_b.vault_path


@pytest.fixture(scope="session")
def vault_c(obsidian_c):
    return obsidian_c.vault_path


# ---------------------------------------------------------------------------
# Session-wide cleanup (runs AFTER all tests)
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session", autouse=True)
def session_cleanup(request, auth_provider):
    """Cleanup runs after the entire session, regardless of pass/fail.

    Captures provider user IDs during setup (before fixtures are torn down)
    so cleanup can run safely during teardown.
    """
    provider_user_ids = []
    for fixture_name in ("sync_user", "isolation_user"):
        try:
            user_tuple = request.getfixturevalue(fixture_name)
            if user_tuple and user_tuple[1]:
                provider_user_ids.append(user_tuple[1])
        except (pytest.FixtureLookupError, pytest.skip.Exception):
            pass

    yield

    # Provider-specific cleanup (e.g., delete Clerk users)
    for uid in provider_user_ids:
        auth_provider.cleanup_user(uid)
    # DB cleanup: delete all e2e-* users + their data
    for pattern in ["e2e-%@example.com", "e2e-%@test.local", "e2e-%@test.com"]:
        try:
            cleanup_test_data(pattern)
        except Exception as e:
            logging.getLogger(__name__).error("DB cleanup failed for %s: %s", pattern, e)
    # Vault cleanup
    cleanup_vaults()
