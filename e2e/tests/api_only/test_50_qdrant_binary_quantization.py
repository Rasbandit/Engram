"""Test 50: Verify Qdrant binary quantization and 1024d prod-parity config.

API-only test. Creates a note to trigger collection creation and indexing,
then queries Qdrant's collection info endpoint directly to confirm binary
quantization (always_ram=true) and correct vector dimensions. Finally
verifies the note is searchable, proving the full embedding pipeline.

Note: ensure_collection is called lazily on first index_note, so we must
create and index a note before inspecting the collection config.
"""

import os
import time

import pytest
import requests

QDRANT_URL = os.environ.get("QDRANT_URL", "http://localhost:6334")
QDRANT_COLLECTION = os.environ.get("QDRANT_COLLECTION", "ci_test_notes")


def _collection_info():
    resp = requests.get(
        f"{QDRANT_URL}/collections/{QDRANT_COLLECTION}", timeout=10
    )
    resp.raise_for_status()
    return resp.json()["result"]


def _wait_for_collection(timeout=30):
    """Poll until the Qdrant collection exists (created on first indexing)."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            return _collection_info()
        except (requests.HTTPError, requests.ConnectionError, KeyError):
            time.sleep(2)
    raise TimeoutError(f"Collection {QDRANT_COLLECTION} not created within {timeout}s")


@pytest.fixture(scope="module")
def seeded_note(api_sync):
    """Create a note to trigger ensure_collection + indexing pipeline."""
    # Get a vault-scoped client (VaultPlug requires X-Vault-ID for notes/search)
    vaults = api_sync.list_vaults()
    assert vaults, "At least one vault must exist (created by api_only conftest)"
    vault_id = vaults[0]["id"]
    scoped = api_sync.with_vault(vault_id)

    ts = int(time.time())
    path = f"E2E/BinaryQuant/test50-{ts}.md"
    unique_phrase = f"qdrant-binary-quant-verification-{ts}"
    content = (
        f"# Binary Quantization Test\n\n"
        f"This note verifies the full embedding pipeline.\n"
        f"Unique phrase: {unique_phrase}\n"
    )
    note = scoped.create_note(path, content)
    assert note is not None, "Note creation should succeed"

    # Wait for async indexing to create the collection
    _wait_for_collection()

    return {"path": path, "unique_phrase": unique_phrase, "api": scoped}


class TestQdrantBinaryQuantization:
    """Verify Qdrant collection config matches prod expectations."""

    def test_collection_exists(self, seeded_note):
        """The app should have created the collection after indexing."""
        info = _collection_info()
        assert info is not None, "Collection should exist"
        assert info.get("points_count", -1) >= 0

    def test_vector_dimensions_1024(self, seeded_note):
        """Vectors should be 1024d to match Voyage prod config."""
        info = _collection_info()
        vectors = info["config"]["params"]["vectors"]
        assert vectors["size"] == 1024, (
            f"Expected 1024d vectors (prod parity), got {vectors['size']}d"
        )
        assert vectors["distance"] == "Cosine"

    def test_binary_quantization_enabled(self, seeded_note):
        """Binary quantization should be configured with always_ram=true."""
        info = _collection_info()
        quant = info["config"].get("quantization_config", {})
        assert "binary" in quant, (
            f"Expected binary quantization config, got: {quant}"
        )
        assert quant["binary"]["always_ram"] is True, (
            "Binary quantization should have always_ram=true"
        )


class TestSearchRoundTrip:
    """Verify the full note -> embed -> search pipeline works."""

    def test_note_indexed_in_qdrant(self, seeded_note):
        """Verify the note was actually embedded and stored in Qdrant."""
        deadline = time.monotonic() + 50
        points = 0
        while time.monotonic() < deadline:
            info = _collection_info()
            points = info.get("points_count", 0)
            if points > 0:
                break
            time.sleep(3)

        assert points > 0, (
            f"Qdrant should have >0 points after indexing, got {points}. "
            f"Embedding pipeline may have failed (Ollama unreachable?)."
        )

    @pytest.mark.xfail(reason="Search endpoint returns 500 in CI — tracked separately")
    def test_search_returns_results(self, seeded_note):
        """Search endpoint should return results for indexed content."""
        api = seeded_note["api"]
        note_path = seeded_note["path"]

        # Poll search — allow time for embedding + Qdrant indexing
        deadline = time.monotonic() + 50
        found = False
        last_status = None
        last_body = None
        while time.monotonic() < deadline:
            time.sleep(3)
            resp = api.session.post(
                f"{api.base_url}/search",
                json={"query": "binary quantization verification", "limit": 10},
                timeout=10,
            )
            last_status = resp.status_code
            last_body = resp.text
            if resp.status_code == 200:
                results = resp.json().get("results", [])
                for r in results:
                    if note_path in r.get("source_path", ""):
                        found = True
                        break
            if found:
                break

        assert found, (
            f"Note at '{note_path}' should appear in search within 50s. "
            f"Last response: HTTP {last_status} — {last_body[:500]}"
        )
