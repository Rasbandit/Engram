"""Fixtures for API-only tests (no Obsidian needed).

These tests run during the Obsidian boot gap in CI.  The freshly
provisioned Clerk user has no vault yet (Obsidian hasn't registered
one), so we create one here to satisfy VaultPlug.
"""

import pytest


@pytest.fixture(scope="session", autouse=True)
def ensure_vault(api_sync):
    """Create a default vault so vault-scoped endpoints don't 404."""
    api_sync.create_vault("e2e-api-only")
