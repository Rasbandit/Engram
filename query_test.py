#!/usr/bin/env python3
"""Quick test script to query Qdrant after indexing.

Usage (run from host or inside a container with access to Qdrant + Ollama):
    pip install qdrant-client httpx
    python query_test.py "what do I know about health"
"""

import sys

import httpx
from qdrant_client import QdrantClient

QDRANT_URL = "http://localhost:6333"
OLLAMA_URL = "http://UNRAID_IP:11434"  # Update this
EMBED_MODEL = "nomic-embed-text"
COLLECTION = "obsidian_notes"


def embed(text: str) -> list[float]:
    resp = httpx.post(
        f"{OLLAMA_URL}/api/embed",
        json={"model": EMBED_MODEL, "input": [text]},
        timeout=30.0,
    )
    resp.raise_for_status()
    return resp.json()["embeddings"][0]


def main():
    if len(sys.argv) < 2:
        print("Usage: python query_test.py <query>")
        sys.exit(1)

    query = " ".join(sys.argv[1:])
    print(f"Query: {query}\n")

    vector = embed(query)
    client = QdrantClient(url=QDRANT_URL)

    results = client.query_points(
        collection_name=COLLECTION,
        query=vector,
        limit=5,
        with_payload=True,
    )

    print(f"Found {len(results.points)} results:\n")
    for i, point in enumerate(results.points, 1):
        p = point.payload
        print(f"--- Result {i} (score: {point.score:.4f}) ---")
        print(f"  Title: {p.get('title')}")
        print(f"  Heading: {p.get('heading_path')}")
        print(f"  Source: {p.get('source_path')}")
        print(f"  Tags: {p.get('tags')}")
        text = p.get("text", "")
        preview = text[:200] + "..." if len(text) > 200 else text
        print(f"  Text: {preview}")
        print()


if __name__ == "__main__":
    main()
