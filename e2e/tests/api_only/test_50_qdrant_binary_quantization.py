"""Test 50: Verify Qdrant binary quantization and 1024d prod-parity config.

API-only test. Queries Qdrant's collection info endpoint directly to confirm
the app created the collection with binary quantization (always_ram=true)
and the correct vector dimensions. Then exercises a note create + search
round-trip to prove the full embedding pipeline works end-to-end.
"""

import os
import time

import pytest
import requests

QDRANT_URL = os.environ.get("QDRANT_URL", "http://localhost:6334")
QDRANT_COLLECTION = os.environ.get("QDRANT_COLLECTION", "ci_test_notes")


class TestQdrantBinaryQuantization:
    """Verify Qdrant collection config matches prod expectations."""

    def _collection_info(self):
        resp = requests.get(
            f"{QDRANT_URL}/collections/{QDRANT_COLLECTION}", timeout=10
        )
        resp.raise_for_status()
        return resp.json()["result"]

    def test_collection_exists(self):
        """The app should have created the collection on boot."""
        info = self._collection_info()
        assert info is not None, "Collection should exist"
        assert info.get("points_count", -1) >= 0

    def test_vector_dimensions_1024(self):
        """Vectors should be 1024d to match Voyage prod config."""
        info = self._collection_info()
        vectors = info["config"]["params"]["vectors"]
        assert vectors["size"] == 1024, (
            f"Expected 1024d vectors (prod parity), got {vectors['size']}d"
        )
        assert vectors["distance"] == "Cosine"

    def test_binary_quantization_enabled(self):
        """Binary quantization should be configured with always_ram=true."""
        info = self._collection_info()
        quant = info["config"].get("quantization_config", {})
        assert "binary" in quant, (
            f"Expected binary quantization config, got: {quant}"
        )
        assert quant["binary"]["always_ram"] is True, (
            "Binary quantization should have always_ram=true"
        )


class TestSearchRoundTrip:
    """Create a note, wait for indexing, search, and verify results."""

    def test_note_to_search_pipeline(self, api_sync):
        """Full pipeline: note upsert -> Oban embed -> Qdrant upsert -> search."""
        ts = int(time.time())
        path = f"E2E/BinaryQuant/test50-{ts}.md"
        unique_phrase = f"qdrant-binary-quant-verification-{ts}"
        content = (
            f"# Binary Quantization Test\n\n"
            f"This note verifies the full embedding pipeline.\n"
            f"Unique phrase: {unique_phrase}\n"
        )

        # Create note via API
        note = api_sync.create_note(path, content)
        assert note is not None, "Note creation should succeed"

        # Wait for async indexing (Oban embed worker has 5s debounce)
        # Poll search until our note appears or timeout
        deadline = time.monotonic() + 30
        found = False
        while time.monotonic() < deadline:
            time.sleep(3)
            resp = api_sync.session.post(
                f"{api_sync.base_url}/search",
                json={"query": unique_phrase, "limit": 5},
                timeout=10,
            )
            if resp.status_code == 200:
                results = resp.json().get("results", [])
                for r in results:
                    if unique_phrase in r.get("text", ""):
                        found = True
                        break
            if found:
                break

        assert found, (
            f"Note with '{unique_phrase}' should appear in search within 30s. "
            f"This proves: Ollama embedded at 1024d -> Qdrant stored with "
            f"binary quantization -> rescore search returned the result."
        )
