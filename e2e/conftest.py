"""Pytest fixtures for Engram E2E tests.

Three Obsidian instances:
- A + B: same user (sync pair — proves two-machine sync)
- C: different user (proves multi-tenant isolation)

All fixtures are session-scoped because Obsidian startup takes ~30s (AppImage
extraction + plugin load). Each test uses unique file paths to avoid
cross-test interference. Per-test vault cleanup is avoided because deleting
files triggers the plugin's file watcher, causing unexpected sync events.
"""

from __future__ import annotations

import asyncio
import logging
import os
import secrets
import shutil
from datetime import datetime
from pathlib import Path

import pytest

from helpers.api import ApiClient
from helpers.cdp import CdpClient
from helpers.cleanup import cleanup_test_data, cleanup_clerk_users, cleanup_vaults
from helpers.clerk import ClerkClient
from helpers.clerk_auth import ClerkAuth, provision_clerk_user
from helpers.obsidian import ObsidianInstance


def pytest_configure(config):
    config.addinivalue_line(
        "markers", "api_only: tests that need no Obsidian instances"
    )


CLERK_SECRET = os.environ.get("E2E_CLERK_SECRET_KEY", "")

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")

API_URL = os.environ.get("ENGRAM_API_URL", "http://localhost:8100/api")
PLUGIN_SRC = Path(os.environ.get("ENGRAM_PLUGIN_SRC", Path(__file__).parent.parent / "plugin"))
OBSIDIAN_BIN = Path.home() / "Applications" / "Obsidian.AppImage"


# ---------------------------------------------------------------------------
# Unique timestamp for this test run
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def ts():
    return datetime.now().strftime("%Y%m%d%H%M%S")


@pytest.fixture(scope="session")
def clerk_client():
    """Clerk Backend API client — None if E2E_CLERK_SECRET_KEY not set."""
    if CLERK_SECRET:
        return ClerkClient(CLERK_SECRET)
    return None


# ---------------------------------------------------------------------------
# Users
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def sync_user(ts, clerk_client):
    """Shared user for Obsidian A + B. Requires Clerk."""
    assert clerk_client is not None, (
        "E2E_CLERK_SECRET_KEY is required — legacy password auth has been removed"
    )
    email = f"e2e-sync-{ts}@example.com"
    password = secrets.token_urlsafe(32)
    clerk_user_id, clerk_auth, api_key = provision_clerk_user(
        clerk_client, email, password, API_URL,
    )
    return email, clerk_user_id, clerk_auth, api_key


@pytest.fixture(scope="session")
def isolation_user(ts, clerk_client):
    """Separate user for Obsidian C. Requires Clerk."""
    assert clerk_client is not None, (
        "E2E_CLERK_SECRET_KEY is required — legacy password auth has been removed"
    )
    email = f"e2e-iso-{ts}@example.com"
    password = secrets.token_urlsafe(32)
    clerk_user_id, clerk_auth, api_key = provision_clerk_user(
        clerk_client, email, password, API_URL,
    )
    return email, clerk_user_id, clerk_auth, api_key


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
        vault_path=Path("/tmp/e2e-vault-a"),
        cdp_port=9250,
        display=":99",
        api_url=API_URL,
        api_key=sync_user[3],
        plugin_src=PLUGIN_SRC,
        obsidian_bin=OBSIDIAN_BIN,
        client_id=sync_client_id,
    )
    inst.start()
    yield inst
    inst.stop()


@pytest.fixture(scope="session")
def obsidian_b(sync_user, sync_client_id):
    """Same user as A — proves two-machine sync."""

    inst = ObsidianInstance(
        name="B",
        vault_path=Path("/tmp/e2e-vault-b"),
        cdp_port=9251,
        display=":98",
        api_url=API_URL,
        api_key=sync_user[3],
        plugin_src=PLUGIN_SRC,
        obsidian_bin=OBSIDIAN_BIN,
        client_id=sync_client_id,
    )
    inst.start()
    yield inst
    inst.stop()


@pytest.fixture(scope="session")
def obsidian_c(isolation_user):
    """Different user — proves multi-tenant isolation."""

    inst = ObsidianInstance(
        name="C",
        vault_path=Path("/tmp/e2e-vault-c"),
        cdp_port=9252,
        display=":97",
        api_url=API_URL,
        api_key=isolation_user[3],
        plugin_src=PLUGIN_SRC,
        obsidian_bin=OBSIDIAN_BIN,
    )
    inst.start()
    yield inst
    inst.stop()


# ---------------------------------------------------------------------------
# CDP clients
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def cdp_a(obsidian_a):
    return CdpClient(port=9250)


@pytest.fixture(scope="session")
def cdp_b(obsidian_b):
    return CdpClient(port=9251)


@pytest.fixture(scope="session")
def cdp_c(obsidian_c):
    return CdpClient(port=9252)


# ---------------------------------------------------------------------------
# API clients
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def api_sync(sync_user):
    """API client using Clerk JWT auth (or API key as fallback)."""
    auth = sync_user[2] if sync_user[2] is not None else sync_user[3]
    return ApiClient(API_URL, auth)


@pytest.fixture(scope="session")
def api_iso(isolation_user):
    """API client using Clerk JWT auth (or API key as fallback)."""
    auth = isolation_user[2] if isolation_user[2] is not None else isolation_user[3]
    return ApiClient(API_URL, auth)


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
def session_cleanup(sync_user, isolation_user, clerk_client):
    """Cleanup runs after the entire session, regardless of pass/fail."""
    yield
    # Clerk user cleanup (delete from Clerk before DB cleanup)
    clerk_user_ids = [
        uid for uid in [sync_user[1], isolation_user[1]] if uid is not None
    ]
    if clerk_client and clerk_user_ids:
        try:
            cleanup_clerk_users(clerk_client, clerk_user_ids)
        except Exception as e:
            logging.getLogger(__name__).error("Clerk cleanup failed: %s", e)
    # DB cleanup: delete all e2e-* users + their data (both email domains)
    for pattern in ["e2e-%@example.com", "e2e-%@test.local"]:
        try:
            cleanup_test_data(pattern)
        except Exception as e:
            logging.getLogger(__name__).error("DB cleanup failed for %s: %s", pattern, e)
    # Vault cleanup
    cleanup_vaults()
