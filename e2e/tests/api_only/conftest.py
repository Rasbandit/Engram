"""Fixtures for API-only tests (no Obsidian needed).

These tests run during the Obsidian boot gap in CI.  The freshly
provisioned Clerk users have no vault yet (Obsidian hasn't registered
one), so we create them here to satisfy VaultPlug.

When AUTH_PROVIDER=local, Clerk fixtures are unavailable so vault
creation is skipped — local auth tests manage their own state.
"""

import os

import pytest

AUTH_PROVIDER = os.environ.get("AUTH_PROVIDER", "local")


@pytest.fixture(scope="session", autouse=True)
def ensure_vaults(request):
    """Create default vaults so vault-scoped endpoints don't 404.

    Skipped when AUTH_PROVIDER != clerk (Clerk fixtures unavailable).
    """
    if AUTH_PROVIDER != "clerk":
        return

    api_sync = request.getfixturevalue("api_sync")
    api_iso = request.getfixturevalue("api_iso")
    api_sync.create_vault("e2e-api-only")
    api_iso.create_vault("e2e-api-only-iso")
