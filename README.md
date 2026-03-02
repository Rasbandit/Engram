# brain

AI-powered personal knowledge base that makes your Obsidian vault queryable by any AI assistant via [MCP](https://modelcontextprotocol.io). Notes are stored in PostgreSQL, embedded into vectors, and searched with a two-stage pipeline (vector retrieval + semantic reranking) that actually understands what you wrote.

Pairs with the [brain-obsidian-sync](https://github.com/Rasbandit/brain-obsidian-sync) plugin for real-time bidirectional sync between Obsidian and the server.

## How It Works

```
                         +-----------------+
                         |    Obsidian     |
                         | (plugin: sync)  |
                         +--------+--------+
                                  |
                    REST API (notes, attachments)
                    SSE (live change stream)
                                  |
                         +--------v--------+
                         |    brain-api    |
                         |   (FastAPI)     |
                         +--+---------+--+-+
                            |         |  |
                  +---------+    +----+  +--------+
                  |              |                 |
          +-------v------+ +----v-----+   +-------v-------+
          |  PostgreSQL  | |  Qdrant  |   |    Ollama     |
          |              | | (vectors)|   | (embeddings)  |
          | notes, auth  | +----+-----+   +---------------+
          | attachments  |      |
          +--------------+      |  (optional)
                          +-----v----------+
                          | Jina Reranker  |
                          | (search boost) |
                          +----------------+
```

### Data Flow

**Indexing** — when a note arrives:

```
POST /notes ─> store in PostgreSQL
                    |
                    v
              parse markdown
          (heading-aware chunking,
           frontmatter extraction)
                    |
                    v
            embed via Ollama
         (nomic-embed-text, 768d)
                    |
                    v
          upsert into Qdrant
       (vectors + rich metadata)
                    |
                    v
         publish SSE event
     (other clients get notified)
```

**Search** — two-stage pipeline:

```
query ──> embed ──> Qdrant (top 4x candidates)
                         |
                         v
                  Jina rerank (top N)
                         |
                         v
                 blend scores (40% vector / 60% rerank)
                         |
                         v
                   return results
```

If Jina is unavailable, search gracefully falls back to vector scores only.

### MCP Integration

Any AI assistant that speaks MCP can query your vault:

```
┌──────────────────────────────────────────────────┐
│  MCP Tools                                       │
│                                                  │
│  search_notes(query, limit, tags)                │
│     → semantic search across your vault          │
│                                                  │
│  get_note(source_path)                           │
│     → fetch full note content                    │
│                                                  │
│  list_tags()                                     │
│     → all tags with document counts              │
│                                                  │
│  list_folders()                                  │
│     → folder tree with note counts               │
│                                                  │
│  write_note(path, content)                       │
│     → update or create a note                    │
│                                                  │
│  create_note(title, content, suggested_folder)   │
│     → auto-places in the best folder             │
└──────────────────────────────────────────────────┘
```

`create_note` is smart about folder placement — it searches for similar content and places the new note alongside related notes.

## Architecture

```
api/
├── main.py                  # FastAPI app, lifespan, route mounting
├── config.py                # All env var configuration
├── auth.py                  # JWT sessions + API key Bearer auth
├── db.py                    # PostgreSQL auth tables (users, api_keys)
├── note_store.py            # PostgreSQL CRUD for notes
├── attachment_store.py      # PostgreSQL CRUD for binary files (images, PDFs)
├── indexing.py              # parse → embed → upsert orchestrator
├── search.py                # Two-stage search (Qdrant + Jina rerank)
├── mcp_tools.py             # MCP server (6 tools)
├── events.py                # PostgreSQL LISTEN/NOTIFY EventBus
├── pool.py                  # PostgreSQL connection pool (psycopg)
├── redis_client.py          # Optional Redis (lazy init)
├── rate_limit.py            # Per-user sliding window rate limiter
├── task_queue.py            # Async background indexing queue
├── parsers/
│   └── markdown.py          # Heading-aware chunking, frontmatter, wikilinks
├── embedders/
│   ├── __init__.py          # Factory (ollama or openai)
│   ├── ollama.py            # Ollama adapter with batch support
│   └── openai.py            # OpenAI adapter with batch support
├── stores/
│   └── qdrant_store.py      # Qdrant vector upsert/delete/search
├── routes/
│   ├── web.py               # Jinja2 + htmx web UI (login, search, settings)
│   └── stream.py            # SSE endpoint for live sync
├── templates/               # HTML templates for web UI
├── alembic/                 # Database migrations
│   └── versions/
│       └── 001_initial_schema.py
├── Dockerfile
└── requirements.txt
```

### Key Design Decisions

- **Single service** — no separate indexer process. Notes are indexed inline on upsert (or optionally via background queue with `ASYNC_INDEXING=true`).
- **Multi-tenant** — all data scoped by `user_id`. Users cannot see each other's notes, searches, or attachments.
- **Adapter pattern** — swap embedding backends (Ollama/OpenAI) or vector stores without touching search logic.
- **Graceful degradation** — Jina reranker is optional. Redis is optional. The system works with just PostgreSQL, Qdrant, and an embedder.
- **Real-time sync** — PostgreSQL `LISTEN/NOTIFY` fans out change events to per-user SSE streams. No polling.

## Quick Start

### Prerequisites

- Docker and Docker Compose
- [Ollama](https://ollama.ai) running with an embedding model
- [Qdrant](https://qdrant.tech) running

Pull the embedding model if you haven't:

```bash
ollama pull nomic-embed-text
```

### 1. Configure

```bash
cp .env.example .env
```

Edit `.env` and set:

```bash
# Point to your Ollama instance
OLLAMA_URL=http://your-ollama-host:11434

# Point to your Qdrant instance
QDRANT_URL=http://your-qdrant-host:6333

# Optional — improves search quality significantly
JINA_URL=http://your-jina-host:8082

# Change in production!
JWT_SECRET=some-random-string-at-least-32-chars
```

### 2. Start

```bash
docker compose up --build
```

This starts:
- **brain-api** on port 8000
- **PostgreSQL** on port 5432
- **Redis** on port 6379

### 3. Register a User

```bash
curl -X POST http://localhost:8000/register \
  -H "Content-Type: application/json" \
  -d '{"email": "you@example.com", "password": "your-password"}'
```

### 4. Create an API Key

```bash
# Login to get a session token
TOKEN=$(curl -s -X POST http://localhost:8000/login \
  -H "Content-Type: application/json" \
  -d '{"email": "you@example.com", "password": "your-password"}' \
  | jq -r '.token')

# Create an API key
curl -X POST http://localhost:8000/api-keys \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "my-key"}'
```

Save the returned API key — it starts with `brain_` and is only shown once.

### 5. Push a Note

```bash
curl -X POST http://localhost:8000/notes \
  -H "Authorization: Bearer brain_your_key_here" \
  -H "Content-Type: application/json" \
  -d '{
    "path": "Notes/Hello World.md",
    "content": "---\ntags: [test, hello]\n---\n# Hello World\n\nThis is my first note.",
    "mtime": 1709234567.0
  }'
```

### 6. Search

```bash
curl -X POST http://localhost:8000/search \
  -H "Authorization: Bearer brain_your_key_here" \
  -H "Content-Type: application/json" \
  -d '{"query": "hello", "limit": 5}'
```

### 7. Connect the Obsidian Plugin

Install [brain-obsidian-sync](https://github.com/Rasbandit/brain-obsidian-sync) via BRAT, then configure:

- **Server URL**: `http://your-server:8000`
- **API Key**: your `brain_` key

The plugin handles full vault sync, live SSE updates, offline queueing, and conflict resolution.

## MCP Configuration

### Claude Code

Add to your Claude Code MCP settings:

```json
{
  "mcpServers": {
    "brain": {
      "type": "sse",
      "url": "http://your-server:8000/mcp",
      "headers": {
        "Authorization": "Bearer brain_your_key_here"
      }
    }
  }
}
```

### Claude Desktop

Add to `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "brain": {
      "url": "http://your-server:8000/mcp",
      "transport": "sse",
      "headers": {
        "Authorization": "Bearer brain_your_key_here"
      }
    }
  }
}
```

Once connected, Claude can search your notes, read full content, browse tags/folders, and even write notes back.

## API Reference

### Notes

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/notes` | Upsert a note (creates or updates, triggers indexing) |
| `GET` | `/notes/{path}` | Get full note by path |
| `DELETE` | `/notes/{path}` | Soft-delete a note |
| `GET` | `/notes/changes?since=<timestamp>` | Notes changed since timestamp (for sync) |

### Search

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/search` | Semantic search with optional tag filtering |
| `GET` | `/tags` | All tags with document counts |
| `GET` | `/folders` | Folder tree with note counts |

### Attachments

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/attachments` | Upsert binary file (base64-encoded) |
| `GET` | `/attachments/{path}` | Get attachment (base64-encoded) |
| `DELETE` | `/attachments/{path}` | Soft-delete attachment |
| `GET` | `/attachments/changes?since=<timestamp>` | Attachment metadata changes (for sync) |
| `GET` | `/user/storage` | Storage usage stats |

### Auth

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/register` | Register a new user |
| `POST` | `/login` | Login, returns JWT |
| `POST` | `/api-keys` | Create an API key (JWT auth) |
| `DELETE` | `/api-keys/{id}` | Revoke an API key |
| `GET` | `/api-keys` | List API keys |

### Live Sync

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/notes/stream` | SSE stream of note/attachment changes |

### System

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/health` | Liveness check |
| `GET` | `/health/deep` | Checks PostgreSQL, Qdrant, Ollama, Redis |

All endpoints except `/health`, `/register`, and `/login` require `Authorization: Bearer <api_key>` header.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DATABASE_URL` | — | PostgreSQL connection string (required) |
| `OLLAMA_URL` | `http://localhost:11434` | Ollama embedding server |
| `QDRANT_URL` | `http://localhost:6333` | Qdrant vector database |
| `JINA_URL` | `http://localhost:8082` | Jina reranker (optional) |
| `EMBED_MODEL` | `nomic-embed-text` | Embedding model name |
| `EMBED_DIMS` | `768` | Vector dimensions |
| `EMBED_BACKEND` | `ollama` | `ollama` or `openai` |
| `OPENAI_API_KEY` | — | Required if `EMBED_BACKEND=openai` |
| `COLLECTION` | `obsidian_notes` | Qdrant collection name |
| `JWT_SECRET` | random | JWT signing key (set in production!) |
| `REGISTRATION_ENABLED` | `true` | Allow new user registration |
| `LOG_LEVEL` | `INFO` | Logging verbosity |
| `PG_POOL_MAX` | `15` | PostgreSQL pool size per worker |
| `MAX_NOTE_SIZE` | `10MB` | Maximum single note size |
| `MAX_ATTACHMENT_SIZE` | `5MB` | Maximum single attachment size |
| `MAX_STORAGE_PER_USER` | `1GB` | Total attachment storage per user |
| `ASYNC_INDEXING` | `false` | Background indexing via task queue |
| `CORS_ORIGINS` | `*` | Comma-separated allowed origins |
| `RATE_LIMIT_RPM` | `120` | Requests per minute per user |
| `REDIS_URL` | — | Optional Redis for caching + rate limiting |

## Embedding Backends

### Ollama (default)

Self-hosted, runs on CPU or GPU. No API keys needed.

```bash
EMBED_BACKEND=ollama
OLLAMA_URL=http://your-ollama-host:11434
EMBED_MODEL=nomic-embed-text
EMBED_DIMS=768
```

### OpenAI

Cloud-hosted, no GPU required. Needs an API key.

```bash
EMBED_BACKEND=openai
OPENAI_API_KEY=sk-...
OPENAI_EMBED_MODEL=text-embedding-3-small
EMBED_DIMS=1536
```

## Testing

The test suite defines the contract that the API must honor — **~97 assertions across 40 sections**.

```bash
# Start services
docker compose up --build -d

# Run tests (requires Ollama + Qdrant reachable)
bash test_plan.sh

# Run tests twice: without Redis, then with Redis
bash test_plan.sh --both
```

Covers: health checks, auth flows, note CRUD, frontmatter extraction, search pipeline, sync, SSE, CORS, attachments, rate limiting, multi-tenant isolation, MCP auth, and more.

## Production Deployment

### Deploy Script

The included `deploy.sh` handles: build, tag, push to registry, deploy via SSH, and optionally build/release the Obsidian plugin.

```bash
# Configure (or put these in .env.deploy)
export BRAIN_REGISTRY="ghcr.io/youruser/brain-api"
export DEPLOY_SERVER="user@your-server"
export DEPLOY_DIR="/opt/brain"        # default: /opt/brain
export DOCKER_NETWORK="ai"            # default: ai

# Deploy
./deploy.sh 1.4.2
```

### Production Architecture

```
your-server
├── Docker network: "ai"
│   ├── brain-api        :8000  ← this project
│   ├── brain-postgres   :5432  ← note + auth storage
│   ├── brain-redis      :6379  ← caching, rate limiting
│   ├── ollama           :11434 ← embedding inference (GPU)
│   ├── qdrant           :6333  ← vector database
│   └── jina-reranker    :8082  ← search quality boost (GPU)
```

### First-Time Server Setup

```bash
# On the remote server:

# Create the shared Docker network
docker network create ai

# Create persistent volume for PostgreSQL
docker volume create brain_pg_data

# Create config directory
mkdir -p /opt/brain

# Generate JWT secret (persists across deploys)
echo "JWT_SECRET=$(openssl rand -base64 32)" > /opt/brain/.env
echo "VERSION=1.4.1" >> /opt/brain/.env
echo "BRAIN_IMAGE=ghcr.io/youruser/brain-api" >> /opt/brain/.env
```

### Manual Operations

```bash
# Check status
ssh user@your-server "docker ps --filter name=brain"

# View logs
ssh user@your-server "docker logs brain-api --tail 50"

# Restart
ssh user@your-server "docker restart brain-api"
```

## Web UI

brain-api includes a built-in web interface at the root URL (`http://your-server:8000/`). Features:

- Login / registration
- Full-text semantic search with tag filtering
- Note viewer
- API key management
- Account settings

Built with Jinja2 templates and htmx — no build step, no JavaScript framework.

## License

MIT
