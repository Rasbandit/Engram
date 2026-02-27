"""Configuration for brain-api."""

import os

OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434")
QDRANT_URL = os.environ.get("QDRANT_URL", "http://localhost:6333")
JINA_URL = os.environ.get("JINA_URL", "http://localhost:8082")
EMBED_MODEL = os.environ.get("EMBED_MODEL", "nomic-embed-text")
COLLECTION = os.environ.get("COLLECTION", "obsidian_notes")
