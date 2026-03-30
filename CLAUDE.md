# CLAUDE.md

> **Workspace:** For cross-project work, open `../engram-workspace/` instead. It provides unified context for both plugin and backend.

Engram — AI-powered personal knowledge base built on an Obsidian vault. Your vault remembers everything. Makes your notes queryable by any AI assistant via MCP.

## Architecture

Engram is the single service — search, MCP server, note storage, indexing, and sync hub. No separate indexer process. Notes come in from the Obsidian plugin (or REST API) and are stored in PostgreSQL, parsed, embedded, and indexed into Qdrant.

### Components (all in `api/`)

- **FastAPI app** (`main.py`) — REST endpoints, MCP server, web UI
- **Note store** (`note_store.py`) — PostgreSQL CRUD for canonical note content
- **Indexing** (`indexing.py`) — orchestrates parse → embed → upsert pipeline
- **Parser** (`parsers/markdown.py`) — heading-aware markdown chunking with frontmatter extraction
- **Qdrant store** (`stores/qdrant_store.py`) — vector upsert/delete operations
- **Embedders** (`embedders/`) — Ollama (default) and OpenAI adapters with batch support
- **Search** (`search.py`) — two-stage pipeline: Qdrant vector search + Jina reranking, 40/60 blend
- **MCP tools** (`mcp_tools.py`) — `search_notes`, `get_note`, `list_tags`, `list_folders`, `write_note`, `create_note`
- **Attachment store** (`attachment_store.py`) — PostgreSQL CRUD for binary attachments (images, PDFs, etc.)
- **Events** (`events.py`) — PostgreSQL LISTEN/NOTIFY EventBus for SSE live sync
- **SSE streaming** (`routes/stream.py`) — per-user real-time change notifications
- **Rate limiting** (`rate_limit.py`) — per-user RPM limiting, Redis or in-memory
- **Redis** (`redis_client.py`) — optional shared state for multi-instance deployments
- **Task queue** (`task_queue.py`) — async background indexing queue
- **Auth** (`auth.py`, `db.py`) — API keys (Bearer), JWT sessions, multi-tenant user isolation

### Key Patterns

- Adapter pattern for embedders (`embedders/ollama.py`, `embedders/openai.py`) and stores (`stores/qdrant_store.py`)
- Graceful fallback: if Jina reranker is unavailable, search uses vector scores only
- All data scoped by user_id for multi-tenancy
- PostgreSQL stores canonical note content; Qdrant stores derived vector embeddings

### Data Flow

```
Obsidian plugin (or curl) → POST /notes → PostgreSQL + parse → Ollama embed → Qdrant upsert
MCP/REST search → Ollama embed query → Qdrant similarity → Jina rerank → blended results
MCP write_note → PostgreSQL + index → plugin pulls on next sync → appears in Obsidian
```

## Local Development

```bash
# Build and run locally (Docker Compose — starts engram + PostgreSQL)
docker compose up --build

# Run engram individually (requires Ollama, Qdrant, Jina, PostgreSQL running)
cd api && uvicorn main:app --host 0.0.0.0 --port 8000

# Push a test note
curl -X POST http://localhost:8000/notes \
  -H "Authorization: Bearer engram_..." \
  -H "Content-Type: application/json" \
  -d '{"path": "Test/Hello.md", "content": "# Hello\nTest note", "mtime": 1709234567.0}'
```

## Environment Variables (see `.env.example`)

| Variable | Default | Purpose |
|----------|---------|---------|
| `OLLAMA_URL` | `http://localhost:11434` | Ollama embedding server |
| `QDRANT_URL` | `http://localhost:6333` | Vector database |
| `JINA_URL` | `http://localhost:8082` | Jina reranker |
| `DATABASE_URL` | — | PostgreSQL connection string |
| `EMBED_MODEL` | `nomic-embed-text` | Embedding model |
| `EMBED_DIMS` | `768` | Vector dimensions |
| `EMBED_BACKEND` | `ollama` | `ollama` or `openai` |
| `COLLECTION` | `obsidian_notes` | Qdrant collection name |
| `JWT_SECRET` | random | JWT signing key |
| `REGISTRATION_ENABLED` | `true` | Allow new users |
| `LOG_LEVEL` | `INFO` | Logging verbosity |
| `PG_POOL_MAX` | `15` | PostgreSQL pool size per worker |
| `MAX_ATTACHMENT_SIZE` | 5MB | Per-file attachment size limit |
| `MAX_STORAGE_PER_USER` | 1GB | Total user storage quota |
| `MAX_NOTE_SIZE` | 10MB | Max single note size |
| `CORS_ORIGINS` | `*` | CORS allowed origins |
| `ASYNC_INDEXING` | `false` | Background indexing (opt-in) |
| `RATE_LIMIT_RPM` | `0` (unlimited) | Requests per minute per user |
| `REDIS_URL` | — | Optional Redis for multi-instance caching |

## Testing

**Notes are king. Tests are the spec. If a test fails, fix the app — not the test.**

Tests rarely need to change. The test suite defines the contract that the API must honor. When tests fail after a code change, the code change is wrong.

### Three test layers

| Layer | Location | Command | What it tests | Infra needed |
|-------|----------|---------|---------------|--------------|
| **Unit tests** | `tests/` | `python3 -m pytest tests/ -v` | Pure logic: sanitize_path, note helpers, auth/JWT, API key cache, rate limiter | None (mocks DB) |
| **Integration tests** | `test_plan.sh` | `bash test_plan.sh` | Full API contract against running services | Docker Compose stack |
| **E2E tests** | `e2e/tests/` | `ENGRAM_API_URL=http://localhost:8100 python3 -m pytest e2e/tests/ -v` | Real Obsidian sync: plugin push/pull, SSE, conflicts, multi-user | CI stack + Obsidian |
| **E2E helper unit tests** | `e2e/unit_tests/` | `python3 -m pytest e2e/unit_tests/ -v` | SQL injection prevention in cleanup helpers | None |

### Unit tests (92 tests)

Fast, no infrastructure. Run from `tests/` or the repo root.

```bash
python3 -m pytest tests/ -v
```

| File | Tests | What it covers |
|------|-------|----------------|
| `test_sanitize_path.py` | 30 | Illegal char stripping, path traversal prevention, unicode, length limits |
| `test_note_helpers.py` | 17 | `_extract_title` (frontmatter, heading, filename fallback), `_extract_tags`, `_extract_folder` |
| `test_auth.py` | 18 | JWT creation/validation/expiry, API key auth (401 on invalid), session cookie auth (303 redirects for expired/tampered/missing tokens) |
| `test_api_key_cache.py` | 14 | Local cache TTL, cache hit skips DB, last_used throttling, cache invalidation on delete, SHA256 hash storage |
| `test_rate_limit.py` | 13 | Unlimited mode, 429 enforcement, per-user isolation, sliding window pruning, boundary behavior |

**Mock pattern:** Unit tests import from `api/` without a database by stubbing heavy dependencies at the top of each test file:

```python
sys.modules.setdefault("psycopg", MagicMock())
sys.modules.setdefault("psycopg.errors", MagicMock())
sys.modules.setdefault("pool", MagicMock())
sys.modules.setdefault("redis_client", MagicMock(is_enabled=MagicMock(return_value=False)))
```

The `conftest.py` adds `api/` to `sys.path`. For functions that call `get_pool()`, use `patch("db.get_pool", return_value=mock_pool)` since `db.py` imports `get_pool` at module level.

### Integration tests (~97 assertions)

```bash
docker compose up --build -d
bash test_plan.sh
```

Covers: health checks, auth, note CRUD, frontmatter extraction, folders/tags, search (vector + rerank), sync changes, SSE live sync, CORS, attachments, size limits, rate limiting, MCP auth, multi-tenant isolation, web UI sessions.

Supports `--both` flag to run twice: without Redis (in-memory) then with Redis.

Requires: engram + postgres running locally (docker compose), plus Ollama and Qdrant reachable for indexing/search tests.

### E2E tests (18 scenarios)

Full Obsidian sync cycle with headless instances. See `../engram-workspace/docs/e2e-testing.md` for architecture, prerequisites, and gotchas.

### E2E helper unit tests (23 tests)

Tests for the E2E test infrastructure itself — SQL injection prevention in `cleanup.py`.

```bash
python3 -m pytest e2e/unit_tests/ -v
```

### CI pipeline

All tests run in GitHub Actions (`.github/workflows/ci.yml`):

1. **Unit tests** — `python3 -m pytest tests/ -v` + `python3 -m pytest e2e/unit_tests/ -v` (no infrastructure)
2. **Integration tests** — starts CI stack, runs `test_plan.sh`
3. **E2E tests** — starts CI stack + headless Obsidian, runs full sync scenarios (main branch only)

## Production Deployment

`deploy.sh` handles the full deploy cycle: build → tag → push to registry → deploy via `docker run` on a remote server → auto-build/release plugin if changed → update docs.

### Deploy Process

Configure via environment variables, then run:

```bash
export ENGRAM_REGISTRY="ghcr.io/youruser/engram"
export DEPLOY_SERVER="user@your-server"
export DEPLOY_DIR="/opt/engram"          # optional, default: /opt/engram
export DOCKER_NETWORK="ai"             # optional, default: ai

./deploy.sh 2.0.0
```

Or set these in a `.env.deploy` and source it before running.

### Manual Operations

```bash
# Check status
ssh user@your-server "docker ps --filter name=engram"

# View logs
ssh user@your-server "docker logs engram --tail 50"

# Restart
ssh user@your-server "docker restart engram"
```

### Production Config

The deploy script creates two files on the remote server at `$DEPLOY_DIR`:
- `docker-compose.yml` — service definitions (synced from `docker-compose.prod.yml` in this repo)
- `.env` — `VERSION`, `ENGRAM_IMAGE`, and `JWT_SECRET` (generated once, persists across deploys)

| Setting | Value |
|---------|-------|
| Network | `ai` (external, shared with ollama, qdrant, jina-reranker) |
| Containers | `engram`, `engram-postgres`, `engram-redis` |
| Port | 8000:8000 |
| Volumes | `engram_pg_data` (PostgreSQL data) |
| Log limits | max-size=50m, max-file=1 |
| Current version | 2.8.1 |

### First-Time Setup

```bash
# On the remote server:

# Ensure volumes exist
docker volume create engram_pg_data

# Create .env with JWT_SECRET
mkdir -p /opt/engram
echo "JWT_SECRET=$(openssl rand -base64 32)" > /opt/engram/.env
echo "VERSION=2.0.0" >> /opt/engram/.env
echo "ENGRAM_IMAGE=ghcr.io/youruser/engram" >> /opt/engram/.env
```

### Infrastructure

The Docker network (default `ai`) connects these containers:
- **engram** — this service (search, MCP, sync, indexing)
- **engram-postgres** — PostgreSQL note + attachment content storage
- **engram-redis** — API key caching, rate limiting (LRU, 128MB max)
- **ollama** (port 11434) — embedding model inference, GPU-accelerated
- **qdrant** (port 6333) — vector database
- **jina-reranker** (port 8082) — Jina reranker for search quality

## Context Docs

If you need info on Starlette/Jinja2 template issues, see `docs/context/starlette-1.0-templates.md`.

## Life OS
project: engram
goal: income
value: financial-freedom

@/home/open-claw/documents/code-projects/ops-agent/docs/self-updating-docs.md
