"""Fixtures for API-only tests (no Obsidian needed).

These tests run during the Obsidian boot gap in CI. The freshly
provisioned users have no vault yet (Obsidian hasn't registered
one), so we create them here to satisfy VaultPlug.

Provider-agnostic: works with both Clerk and local auth.
"""

import pytest


@pytest.fixture(scope="session", autouse=True)
def ensure_vaults(api_sync, api_iso):
    """Create default vaults so vault-scoped endpoints don't 404."""
    api_sync.create_vault("e2e-api-only")
    api_iso.create_vault("e2e-api-only-iso")
