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

# Feature flags
REGISTRATION_ENABLED = os.environ.get("REGISTRATION_ENABLED", "true").lower() == "true"

# Embedding backend: "ollama" (default) or "openai"
EMBED_BACKEND = os.environ.get("EMBED_BACKEND", "ollama")

# PostgreSQL pool
PG_POOL_MAX = int(os.environ.get("PG_POOL_MAX", "15"))

# Attachments
MAX_ATTACHMENT_SIZE = int(os.environ.get("MAX_ATTACHMENT_SIZE", str(5 * 1024 * 1024)))  # 5MB
MAX_STORAGE_PER_USER = int(os.environ.get("MAX_STORAGE_PER_USER", str(1024 * 1024 * 1024)))  # 1GB

# Note size limit
MAX_NOTE_SIZE = int(os.environ.get("MAX_NOTE_SIZE", str(10 * 1024 * 1024)))  # 10MB

# CORS
CORS_ORIGINS = [o.strip() for o in os.environ.get("CORS_ORIGINS", "*").split(",") if o.strip()]

# Async indexing (opt-in — default false for sync test compatibility)
ASYNC_INDEXING = os.environ.get("ASYNC_INDEXING", "false").lower() == "true"

# Rate limiting
RATE_LIMIT_RPM = int(os.environ.get("RATE_LIMIT_RPM", "120"))

# Redis (optional — enables shared state for multi-instance deployments)
REDIS_URL = os.environ.get("REDIS_URL") or None  # None/empty = disabled, use in-memory backends
