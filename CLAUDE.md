# CLAUDE.md

AI-powered personal knowledge base built on an Obsidian vault. Makes your notes queryable by any AI assistant via MCP.

## Architecture

brain-api is the single service — search, MCP server, note storage, indexing, and sync hub. No separate indexer process. Notes come in from the Obsidian plugin (or REST API) and are stored in PostgreSQL, parsed, embedded, and indexed into Qdrant.

### Components (all in `api/`)

- **FastAPI app** (`main.py`) — REST endpoints, MCP server, web UI
- **Note store** (`note_store.py`) — PostgreSQL CRUD for canonical note content
- **Indexing** (`indexing.py`) — orchestrates parse → embed → upsert pipeline
- **Parser** (`parsers/markdown.py`) — heading-aware markdown chunking with frontmatter extraction
- **Qdrant store** (`stores/qdrant_store.py`) — vector upsert/delete operations
- **Embedders** (`embedders/`) — Ollama (default) and OpenAI adapters with batch support
- **Search** (`search.py`) — two-stage pipeline: Qdrant vector search + Jina reranking, 40/60 blend
- **MCP tools** (`mcp_tools.py`) — `search_notes`, `get_note`, `list_tags`, `list_folders`, `write_note`, `create_note`
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
# Build and run locally (Docker Compose — starts brain-api + PostgreSQL)
docker compose up --build

# Run brain-api individually (requires Ollama, Qdrant, Jina, PostgreSQL running)
cd api && uvicorn main:app --host 0.0.0.0 --port 8000

# Push a test note
curl -X POST http://localhost:8000/notes \
  -H "Authorization: Bearer brain_..." \
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
| `DB_PATH` | `/data/brain.db` | SQLite auth database |
| `REGISTRATION_ENABLED` | `true` | Allow new users |
| `LOG_LEVEL` | `INFO` | Logging verbosity |

## Testing

**Notes are king. Tests are the spec. If a test fails, fix the app — not the test.**

Tests rarely need to change. The test suite defines the contract that the API must honor. When tests fail after a code change, the code change is wrong.

```bash
# Start services, then run tests
docker compose up --build -d
bash test_plan.sh
```

`test_plan.sh` covers 75 assertions across 16 sections:
- Health check
- Auth (registration, login, API keys, Bearer validation)
- Note CRUD lifecycle (create, read, upsert/update, delete)
- Frontmatter extraction (title, tags, folder)
- Legacy endpoints (`GET /note?source_path=`)
- Folders and tags from PostgreSQL
- Search (vector + rerank, tag filtering, limit validation)
- Sync (`GET /notes/changes` with timestamps)
- Edge cases (empty content, unicode, special chars, long content, invalid input)
- Multi-tenant isolation (users cannot see each other's data)
- Web UI session routes
- Cleanup

Requires: brain-api + postgres running locally (docker compose), plus Ollama and Qdrant reachable for indexing/search tests.

## Production Deployment — FastRaid (Unraid)

The brain-api runs on FastRaid (10.0.20.214), an Unraid server managed via Unraid's Docker UI (dockerman).

### Server Access

```bash
ssh root@10.0.20.214   # always root — no other user on Unraid
```

### Container Registry

Images are pushed to GHCR: `ghcr.io/rasbandit/brain-api:<version>`

### Deploy Process

Use `./deploy.sh <version>` which handles: build → tag → push to GHCR → pull on FastRaid → replace container → update Unraid template → update docs.

Manual deploy if needed:

```bash
# 1. Build locally
docker compose build brain-api

# 2. Tag and push to GHCR
docker tag edi-brain-brain-api:latest ghcr.io/rasbandit/brain-api:<version>
docker tag edi-brain-brain-api:latest ghcr.io/rasbandit/brain-api:latest
docker push ghcr.io/rasbandit/brain-api:<version>
docker push ghcr.io/rasbandit/brain-api:latest

# 3. Pull and replace on FastRaid
ssh root@10.0.20.214 "docker pull ghcr.io/rasbandit/brain-api:<version>"
ssh root@10.0.20.214 "docker stop brain-api && docker rm brain-api"
ssh root@10.0.20.214 "docker run -d \
  --name brain-api \
  --network ai \
  -p 8000:8000 \
  -v brain_data:/data \
  -e TZ=America/Los_Angeles \
  -e EMBED_MODEL=nomic-embed-text \
  -e EMBED_BACKEND=ollama \
  -e DATABASE_URL=postgresql://brain:password@postgresql:5432/brain \
  -e JWT_SECRET=\${JWT_SECRET:-$(openssl rand -base64 32)} \
  -e DB_PATH=/data/brain.db \
  -e REGISTRATION_ENABLED=true \
  -e HOST_OS=Unraid \
  -e HOST_HOSTNAME=unraid-fast \
  -e HOST_CONTAINERNAME=brain-api \
  -e OLLAMA_URL=http://ollama:11434 \
  -e QDRANT_URL=http://qdrant:6333 \
  -e JINA_URL=http://jinareranker:8082 \
  -e COLLECTION=obsidian_notes \
  -e LOG_LEVEL=INFO \
  --log-opt max-size=50m \
  --log-opt max-file=1 \
  -l net.unraid.docker.managed=dockerman \
  ghcr.io/rasbandit/brain-api:<version>"

# 4. Update the Unraid Docker template
ssh root@10.0.20.214 "sed -i 's|brain-api:[0-9.]*|brain-api:<version>|' /boot/config/plugins/dockerMan/templates-user/my-brain-api.xml"
```

### Production Container Config

| Setting | Value |
|---------|-------|
| Network | `ai` (shared with ollama, qdrant, jinareranker, postgresql) |
| Port | 8000:8000 |
| Volumes | `brain_data:/data` (SQLite auth DB) |
| Log limits | max-size=50m, max-file=1 |
| Label | `net.unraid.docker.managed=dockerman` |
| Current version | 1.2.2 |

### Infrastructure on FastRaid

The `ai` Docker network connects these containers:
- **brain-api** — this service (search, MCP, sync, indexing)
- **ollama** (port 11434) — embedding model inference, GPU-accelerated
- **qdrant** (port 6333) — vector database
- **jinareranker** (port 8082) — Jina reranker for search quality
- **postgresql** (port 5432) — note content storage
