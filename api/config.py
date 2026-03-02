"""Configuration for brain-api."""

import os
import secrets

OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434")
QDRANT_URL = os.environ.get("QDRANT_URL", "http://localhost:6333")
JINA_URL = os.environ.get("JINA_URL", "http://localhost:8082")
EMBED_MODEL = os.environ.get("EMBED_MODEL", "nomic-embed-text")
EMBED_DIMS = int(os.environ.get("EMBED_DIMS", "768"))
COLLECTION = os.environ.get("COLLECTION", "obsidian_notes")

# PostgreSQL
DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql://brain:brain@localhost:5432/brain")

# Auth
JWT_SECRET = os.environ.get("JWT_SECRET", secrets.token_urlsafe(32))
DB_PATH = os.environ.get("DB_PATH", "/data/brain.db")

# Feature flags
REGISTRATION_ENABLED = os.environ.get("REGISTRATION_ENABLED", "true").lower() == "true"

# Embedding backend: "ollama" (default) or "openai"
EMBED_BACKEND = os.environ.get("EMBED_BACKEND", "ollama")
