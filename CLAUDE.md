# CLAUDE.md

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
| `RATE_LIMIT_RPM` | `120` | Requests per minute per user |
| `REDIS_URL` | — | Optional Redis for multi-instance caching |

## Testing

**Notes are king. Tests are the spec. If a test fails, fix the app — not the test.**

Tests rarely need to change. The test suite defines the contract that the API must honor. When tests fail after a code change, the code change is wrong.

```bash
# Start services, then run tests
docker compose up --build -d
bash test_plan.sh
```

`test_plan.sh` covers ~97 assertions across 40 sections:
- Health check + deep health (PostgreSQL, Qdrant, Ollama, Redis)
- Auth (registration, login, API key management, API key deletion + cache invalidation, Bearer validation)
- Note CRUD lifecycle (create, read, upsert/update, delete, double-delete)
- Frontmatter extraction (title, tags, folder, comma-separated tags)
- Root-level notes + title fallback
- Legacy endpoints (`GET /note?source_path=`)
- Folders and tags from PostgreSQL
- Search (vector + rerank, tag filtering, multi-tag filter, limit validation, result fields)
- Sync (`GET /notes/changes` with timestamps, changes response shape)
- SSE live sync + SSE user isolation
- CORS
- Attachments (CRUD, upsert, changes, edge cases, double-delete)
- Note size limit (413)
- Rate limiting
- MCP auth
- Multi-tenant isolation (users cannot see each other's data, multi-tenant search)
- Web UI session routes + logout
- Cleanup

Supports `--both` flag to run tests twice: without Redis (in-memory) then with Redis.

Requires: engram + postgres running locally (docker compose), plus Ollama and Qdrant reachable for indexing/search tests.

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
| Current version | 1.4.1 |

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
