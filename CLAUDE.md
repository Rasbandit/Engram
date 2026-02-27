# CLAUDE.md

AI-powered personal knowledge base built on an Obsidian vault.

## Architecture

Three loosely-coupled Python 3.12 services communicating via Qdrant (vector DB):

1. **Indexer** (`indexer/`) — Watches the Obsidian vault with `watchdog`, parses markdown into chunks (heading-based splitting, 512-token max via tiktoken), embeds via Ollama, upserts to Qdrant. Tracks file mtimes in SQLite to skip unchanged files.
2. **API** (`api/`) — FastAPI service (port 8000) with two-stage search: vector similarity from Qdrant, then Jina reranking, blended 40/60. Also serves as the MCP server (FastMCP, port 8000) exposing `search_notes`, `get_note`, `list_tags` tools for Claude integration.

### Key Patterns

- Adapter pattern for embedders (`embedders/ollama.py`), stores (`stores/qdrant_store.py`), parsers (`parsers/markdown.py`)
- Graceful fallback: if Jina reranker is unavailable, search uses vector scores only
- Each service has its own `requirements.txt` and `Dockerfile`

## Local Development

```bash
# Build and run locally (Docker Compose)
docker compose up --build

# Run services individually (requires Ollama, Qdrant, Jina running)
python indexer/main.py
uvicorn api.main:app --host 0.0.0.0 --port 8000

# Test a query
python query_test.py "search terms"
```

## Environment Variables (see `.env.example`)

`OLLAMA_URL`, `QDRANT_URL`, `JINA_URL`, `VAULT_PATH`, `STATE_DIR`, `EMBED_MODEL` (default: nomic-embed-text), `EMBED_DIMS` (768), `BRAIN_API_URL`, `PORT`, `LOG_LEVEL`

## Production Deployment — FastRaid (Unraid)

The brain-api runs on FastRaid (10.0.20.214), an Unraid server managed via Unraid's Docker UI (dockerman).

### Server Access

```bash
ssh root@10.0.20.214   # always root — no other user on Unraid
```

### Container Registry

Images are pushed to GHCR: `ghcr.io/rasbandit/brain-api:<version>`

### Deploy Process

```bash
# 1. Build locally
docker compose build brain-api

# 2. Tag and push to GHCR (bump version as needed)
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
  -e TZ=America/Los_Angeles \
  -e EMBED_MODEL=nomic-embed-text \
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

# 5. Update the Unraid Docker template to match the new version
ssh root@10.0.20.214 "sed -i 's|brain-api:[0-9.]*|brain-api:<version>|' /boot/config/plugins/dockerMan/templates-user/my-brain-api.xml"

# 6. Do NOT run the containers locally after building — this machine is for dev only
```

### Production Container Config

| Setting | Value |
|---------|-------|
| Network | `ai` (shared with ollama, qdrant, jinareranker) |
| Port | 8000:8000 |
| Log limits | max-size=50m, max-file=1 |
| Label | `net.unraid.docker.managed=dockerman` |
| Current version | 1.1.0 |

### Infrastructure on FastRaid

The `ai` Docker network connects these containers:
- **brain-api** — this service
- **ollama** (port 11434) — LLM inference, GPU-accelerated
- **qdrant** (port 6333) — vector database
- **jinareranker** (port 8082) — Jina reranker for search
