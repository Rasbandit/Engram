"""Pytest fixtures for Engram E2E tests.

Three Obsidian instances:
- A + B: same user (sync pair — proves two-machine sync)
- C: different user (proves multi-tenant isolation)
"""

from __future__ import annotations

import asyncio
import logging
import os
import shutil
from datetime import datetime
from pathlib import Path

import pytest

from helpers.api import ApiClient, register_user
from helpers.cdp import CdpClient
from helpers.cleanup import cleanup_test_data, cleanup_vaults
from helpers.obsidian import ObsidianInstance

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")

API_URL = os.environ.get("ENGRAM_API_URL", "http://localhost:8100")
PLUGIN_SRC = Path(os.environ.get("ENGRAM_PLUGIN_SRC", str(Path(__file__).parent.parent / "plugin-src")))
OBSIDIAN_BIN = Path(os.environ.get("ENGRAM_OBSIDIAN_BIN", str(Path.home() / "Applications" / "Obsidian.AppImage")))


# ---------------------------------------------------------------------------
# Unique timestamp for this test run
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def ts():
    return datetime.now().strftime("%Y%m%d%H%M%S")


# ---------------------------------------------------------------------------
# Users
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def sync_user(ts):
    """Shared user for Obsidian A + B. Returns (email, api_key)."""
    email = f"e2e-sync-{ts}@test.local"
    api_key = register_user(API_URL, email, "testpass123")
    return email, api_key


@pytest.fixture(scope="session")
def isolation_user(ts):
    """Separate user for Obsidian C. Returns (email, api_key)."""
    email = f"e2e-iso-{ts}@test.local"
    api_key = register_user(API_URL, email, "testpass123")
    return email, api_key


# ---------------------------------------------------------------------------
# Obsidian instances
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def obsidian_a(sync_user):

    inst = ObsidianInstance(
        name="A",
        vault_path=Path("/tmp/e2e-vault-a"),
        cdp_port=9250,
        display=":99",
        api_url=API_URL,
        api_key=sync_user[1],
        plugin_src=PLUGIN_SRC,
        obsidian_bin=OBSIDIAN_BIN,
    )
    inst.start()
    yield inst
    inst.stop()


@pytest.fixture(scope="session")
def obsidian_b(sync_user):
    """Same user as A — proves two-machine sync."""

    inst = ObsidianInstance(
        name="B",
        vault_path=Path("/tmp/e2e-vault-b"),
        cdp_port=9251,
        display=":98",
        api_url=API_URL,
        api_key=sync_user[1],
        plugin_src=PLUGIN_SRC,
        obsidian_bin=OBSIDIAN_BIN,
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
        api_key=isolation_user[1],
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
    return ApiClient(API_URL, sync_user[1])


@pytest.fixture(scope="session")
def api_iso(isolation_user):
    return ApiClient(API_URL, isolation_user[1])


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
def session_cleanup(sync_user, isolation_user):
    """Cleanup runs after the entire session, regardless of pass/fail."""
    yield
    # DB cleanup: delete all e2e-* users + their data
    try:
        cleanup_test_data()
    except Exception as e:
        logging.getLogger(__name__).error("DB cleanup failed: %s", e)
    # Vault cleanup
    cleanup_vaults()
