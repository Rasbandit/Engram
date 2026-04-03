# CLAUDE.md

> **Workspace:** For cross-project work, open `../engram-workspace/` instead. It provides unified context for both plugin and backend.

Engram — AI-powered personal knowledge base built on Obsidian. Your vault remembers everything. Makes your notes queryable by any AI assistant via MCP. SaaS-only at launch: Starter $5/mo, Pro $10/mo. See `docs/context/pricing-strategy.md`.

## Architecture

> **Migration in progress (2026-04-02):** Engram is being rewritten from Python/FastAPI to **Elixir/Phoenix**. SSE replaced by Phoenix Channels (WebSocket). PostgreSQL LISTEN/NOTIFY replaced by Phoenix PubSub (Erlang distribution). See [Elixir Migration Plan](#elixir-migration-plan) for full details.

Engram is a single OTP application — search, MCP server, note storage, indexing, and real-time sync hub. Notes come in from the Obsidian plugin (or REST API) and are stored in PostgreSQL, parsed, embedded, and indexed into Qdrant. Real-time sync uses Phoenix Channels over WebSocket.

### Deployment Modes

| Mode | Language | Real-time | Embedding | Vector DB | PostgreSQL | Attachments | Reranker |
|------|----------|-----------|-----------|-----------|------------|-------------|----------|
| **SaaS** (primary) | Elixir/Phoenix | Phoenix Channels (WebSocket) | Voyage AI API (`voyage-4-large`, 1024d) | Qdrant Cloud | Fly Postgres | Fly Tigris (S3) | None (planned: Voyage Rerank 2.5 or Jina API) |
| **Local dev / CI** | Elixir/Phoenix | Phoenix Channels (WebSocket) | Ollama (local, e.g., nomic-embed-text 768d) | Qdrant (Docker) | PostgreSQL (Docker) | Local filesystem or S3 | Optional (Jina self-hosted) |

### Target Components (Elixir/Phoenix OTP App)

- **Phoenix Endpoint** (`lib/engram_web/endpoint.ex`) — HTTP + WebSocket entry point
- **Router** (`lib/engram_web/router.ex`) — REST API routes, MCP endpoint, web UI
- **Sync Channel** (`lib/engram_web/channels/sync_channel.ex`) — per-user WebSocket channel for real-time bidirectional sync (replaces SSE + LISTEN/NOTIFY)
- **Presence** (`lib/engram_web/presence.ex`) — tracks connected devices per user (built-in Phoenix Presence)
- **Notes Context** (`lib/engram/notes.ex`) — Note CRUD, folder operations (Ecto schemas + repo)
- **Indexing** (`lib/engram/indexing.ex`) — orchestrates parse → contextualize → embed → upsert pipeline
- **Parser** (`lib/engram/parsers/markdown.ex`) — heading-aware chunking via Earmark AST, structure preservation (code blocks, lists, tables)
- **Qdrant Client** (`lib/engram/vector/qdrant.ex`) — thin HTTP wrapper over Qdrant REST API (~150 LOC, via Req)
- **Embedders** (`lib/engram/embedders/`) — Voyage AI (SaaS default, via Req HTTP), Ollama (self-hosted) adapters
- **Search** (`lib/engram/search.ex`) — vector search via Qdrant, optional reranking, BM25 hybrid planned
- **MCP Server** (`lib/engram/mcp/`) — MCP tool definitions via Hermes MCP or `mcp` package
- **Attachment Store** (`lib/engram/attachments.ex`) — Fly Tigris S3 (via ExAws) or local filesystem
- **Auth** (`lib/engram/auth.ex`) — API keys (Bearer via Plug), JWT sessions (Joken), RLS tenant context, Argon2 password hashing
- **Oban Workers** (`lib/engram/workers/`) — `EmbedNote` (per-note embedding with dedup/debounce), `ReindexAll` (bulk re-embedding), `PurgeSoftDeletes`, `RetryDiscarded`, `OrphanChunkScan`
- **Rate Limiting** — Hammer (token bucket, ETS or Redis backend)
- **PubSub** — Phoenix.PubSub.PG2 (native Erlang distribution, no Redis needed)
- **Clustering** — dns_cluster for Fly.io node discovery via `.internal` DNS

### Key Patterns

- **OTP supervision tree** — `one_for_one` strategy: independent worker processes. Channel crashes don't affect Oban, Oban crashes don't affect Channels. Standard Phoenix supervision with Oban supervisor added to application children. Restart intensity: Phoenix defaults (3 restarts in 5 seconds)
- **Phoenix Channels + PubSub** — bidirectional real-time sync, cluster-wide broadcast via Erlang distribution (no Redis, no message broker)
- **PostgreSQL RLS (Row-Level Security)** — DB-enforced tenant isolation via `SET LOCAL app.current_tenant` per transaction. Defense-in-depth beyond app-level `user_id` filtering. `Repo.prepare_query` safety net raises if tenant-scoped tables are queried without `with_tenant/2`
- **Two DB roles** — `engram_owner` (migrations, bypasses RLS) and `engram_app` (runtime, subject to RLS policies)
- **Behaviour-based adapters** — `Engram.Embedder` behaviour for Voyage/Ollama, matching Elixir conventions
- **Graceful fallback** — if reranker is unavailable, search uses vector scores only
- **Voyage 4 shared embedding space** — `voyage-4-large` (SaaS) and `voyage-4-nano` (API) produce interchangeable vectors. Self-hosted uses Ollama (separate vector space, not interchangeable)
- **Folder-aware context** — folder path + heading hierarchy prepended to chunk text before embedding for richer vectors
- **In-process caching** — ETS tables for API key cache, rate limiting (clustered via PubSub if needed, no Redis dependency)
- **Async indexing, sync note storage** — note upsert returns immediately after Postgres write + PubSub broadcast; embedding is queued via Oban (5s debounce, dedup per note, retry on failure)
- **Hybrid chunk storage** — Postgres `chunks` table = source of truth for chunk boundaries/positions; Qdrant = vectors + contextualized text. Enables parent-child retrieval and reliable re-indexing

### Data Flow (SaaS)

```
Obsidian plugin → WebSocket connect → Phoenix Channel "sync:{user_id}" → Presence tracks device

SYNC PATH (immediate):
  Plugin pushes note → Channel handler → Fly Postgres upsert (version++, content_hash)
    → PubSub broadcast_from → all OTHER connected devices receive note_changed
    → Reply to sender with {note, indexing: "queued"}

INDEXING PATH (async via Oban, 5s debounce):
  Oban EmbedNote worker picks up job → fetch latest content from DB
    → Earmark parse → contextualize (prepend folder/heading) → Voyage AI batch embed (1024d)
    → Delete old chunks (Postgres + Qdrant) → Insert new chunks
    → On failure: retry with backoff (30s → 2m → 15m → 1h → discard)

SEARCH PATH:
  MCP/REST search → Voyage AI embed query → Qdrant Cloud similarity → return top N

ATTACHMENTS:
  Fly Tigris (S3-compatible via ExAws) for upload/download
```

### Data Flow (Self-hosted)

```
Obsidian plugin → WebSocket connect → Phoenix Channel "sync:{user_id}"

SYNC PATH (immediate):
  Plugin pushes note → Channel → PostgreSQL upsert (version++, content_hash)
    → PubSub broadcast → connected devices receive change

INDEXING PATH (async via Oban):
  Oban worker → fetch latest from DB → parse → contextualize → Ollama embed (768d) → Qdrant upsert

SEARCH PATH:
  MCP/REST search → Ollama embed query → Qdrant similarity → optional Jina rerank → blended results
```

## Local Development

### Elixir/Phoenix (target — on FastRaid via Docker)

```bash
# Build and run locally (Docker Compose — Elixir app + PostgreSQL + Qdrant)
# App runs in Docker on FastRaid, connects to real Voyage AI + Qdrant Cloud + Tigris
docker compose up --build

# Run outside Docker (requires Elixir 1.17+, PostgreSQL, Qdrant)
mix deps.get
mix ecto.setup          # Create DB + run migrations + seeds
mix phx.server          # Start on http://localhost:4000

# IEx console (attached to running app)
iex -S mix phx.server

# Push a test note
curl -X POST http://localhost:4000/notes \
  -H "Authorization: Bearer engram_..." \
  -H "Content-Type: application/json" \
  -d '{"path": "Test/Hello.md", "content": "# Hello\nTest note", "mtime": 1709234567.0}'
```

### Python/FastAPI (current — being replaced)

```bash
# Still works for running existing tests and current production
docker compose up --build
cd api && uvicorn main:app --host 0.0.0.0 --port 8000
```

## Environment Variables

### Core (Elixir)

| Variable | Default | Purpose |
|----------|---------|---------|
| `DATABASE_URL` | — | PostgreSQL connection string (auto-set by Fly Postgres) |
| `SECRET_KEY_BASE` | — | Phoenix secret (auto-generated by `fly launch`) |
| `PHX_HOST` | `localhost` | Phoenix host for URL generation |
| `PORT` | `4000` | HTTP listen port (8080 on Fly) |
| `DNS_CLUSTER_QUERY` | — | Fly clustering DNS (auto-set: `<app>.internal`) |
| `RELEASE_COOKIE` | — | Erlang distribution cookie (pin as Fly secret) |
| `QDRANT_URL` | `http://localhost:6333` | Vector database (Qdrant Cloud URL for SaaS) |
| `QDRANT_API_KEY` | — | Qdrant Cloud API key (not needed for local) |
| `QDRANT_COLLECTION` | `obsidian_notes` | Qdrant collection name |

### Embedding

| Variable | Default | Purpose |
|----------|---------|---------|
| `EMBED_BACKEND` | `ollama` | `voyage` (SaaS) or `ollama` (self-hosted) |
| `EMBED_MODEL` | `nomic-embed-text` | Embedding model name (`voyage-4-large` for SaaS) |
| `EMBED_DIMS` | `768` | Vector dimensions (1024 for Voyage, 768 for nomic) |
| `VOYAGE_API_KEY` | — | Voyage AI API key (required when `EMBED_BACKEND=voyage`) |
| `OLLAMA_URL` | `http://localhost:11434` | Ollama server (self-hosted only) |

### Search (optional)

| Variable | Default | Purpose |
|----------|---------|---------|
| `JINA_URL` | — | Reranker URL (empty = vector-only search) |

### Attachments

| Variable | Default | Purpose |
|----------|---------|---------|
| `ATTACHMENT_BACKEND` | `local` | `tigris` (SaaS) or `local` (self-hosted) |
| `TIGRIS_BUCKET` | — | Tigris S3 bucket name (auto-set by `fly storage create`) |
| `TIGRIS_ACCESS_KEY_ID` | — | Tigris access key (auto-set by Fly) |
| `TIGRIS_SECRET_ACCESS_KEY` | — | Tigris secret key (auto-set by Fly) |
| `TIGRIS_ENDPOINT_URL` | `https://fly.storage.tigris.dev` | Tigris S3 endpoint |

### Auth

| Variable | Default | Purpose |
|----------|---------|---------|
| `JWT_SECRET` | — | JWT signing key (Joken signer) |
| `REGISTRATION_ENABLED` | `true` | Allow new user registration |

### Limits & Features

| Variable | Default | Purpose |
|----------|---------|---------|
| `POOL_SIZE` | `10` | Ecto PostgreSQL pool size |
| `MAX_ATTACHMENT_SIZE` | `5242880` | Per-file attachment size limit (bytes) |
| `MAX_STORAGE_PER_USER` | `1073741824` | Total user storage quota (bytes) |
| `MAX_NOTE_SIZE` | `10485760` | Max single note size (bytes) |
| `RATE_LIMIT_RPM` | `0` (unlimited) | Requests per minute per user (Hammer) |
| `REDIS_URL` | — | Optional Redis (only needed if not using ETS for rate limiting) |

### Observability

| Variable | Default | Purpose |
|----------|---------|---------|
| `SENTRY_DSN` | — | Sentry error tracking DSN (empty = disabled) |

## Testing

**Notes are king. Tests are the spec. If a test fails, fix the app — not the test.**

### Testing Strategy (Elixir Migration)

The existing **integration tests** (`test_plan.sh`, ~97 assertions) and **E2E tests** (`e2e/tests/`, 42 scenarios) are HTTP-based — they hit the API via curl/requests and don't care about the backend language. These become the **migration acceptance gate**: when all integration + E2E tests pass against the Elixir backend, migration is complete.

**Unit tests** are language-specific and will be rewritten in ExUnit as each module is built.

### Test Layers (Target — Elixir)

| Layer | Location | Command | What it tests | Infra needed |
|-------|----------|---------|---------------|--------------|
| **Unit tests** | `test/` | `mix test` | Pure logic: path sanitization, note helpers, auth, RLS context | None (Ecto.Sandbox) |
| **Integration tests** | `test_plan.sh` | `bash test_plan.sh` | Full API contract (HTTP-based, language-agnostic) | Docker Compose stack |
| **E2E tests** | `e2e/tests/` | `python3 -m pytest e2e/tests/ -v` | Real Obsidian sync: push/pull, Channels, conflicts, multi-user | CI stack + Obsidian |
| **E2E helper unit tests** | `e2e/unit_tests/` | `python3 -m pytest e2e/unit_tests/ -v` | SQL injection prevention in cleanup helpers | None |

### Elixir Testing Stack

| Tool | Purpose | Equivalent of |
|------|---------|---------------|
| **ExUnit** | Test framework | pytest |
| **Ecto.Adapters.SQL.Sandbox** | Per-test DB transactions (auto-rollback) | pytest fixtures + cleanup |
| **ExMachina** | Test data factories | Factory Boy |
| **Mox** | Behaviour-based mocks (embedder, Qdrant client) | unittest.mock |
| **Bypass** | HTTP mock server (for Voyage AI, Qdrant API) | responses/httpretty |

Key advantage: `async: true` runs tests in parallel with per-test DB transactions. No cleanup needed.

### RLS Testing (Critical)

Every test must verify tenant isolation:
- Query as User A with User B's tenant context → must return zero rows
- Insert as User A, attempt read as User B → must fail
- `FORCE ROW LEVEL SECURITY` means even the table owner can't bypass policies

### Current Python Tests (Migration Reference)

These remain as the **spec** during migration. Each passing test = one verified behavior.

**Unit tests (92 tests):** `python3 -m pytest tests/ -v`

| File | Tests | What it covers |
|------|-------|----------------|
| `test_sanitize_path.py` | 30 | Illegal char stripping, path traversal prevention, unicode, length limits |
| `test_note_helpers.py` | 17 | Title/tags/folder extraction from markdown |
| `test_auth.py` | 18 | JWT creation/validation/expiry, API key auth, session cookies |
| `test_api_key_cache.py` | 14 | Cache TTL, DB fallback, throttling, invalidation |
| `test_rate_limit.py` | 13 | 429 enforcement, per-user isolation, sliding window |

**Integration tests (~97 assertions):** `bash test_plan.sh` — health, auth, CRUD, search, sync, SSE, attachments, rate limiting, MCP auth, multi-tenant isolation

**E2E tests (42 scenarios):** `python3 -m pytest e2e/tests/ -v` — real Obsidian sync cycles (these stay as-is, they're language-agnostic)

### CI Pipeline

All tests run in GitHub Actions (`.github/workflows/ci.yml`):

1. **Unit tests** — `mix test` (Elixir) + `python3 -m pytest e2e/unit_tests/ -v` (E2E helpers)
2. **Integration tests** — starts CI stack, runs `test_plan.sh`
3. **E2E tests** — starts CI stack + headless Obsidian, runs full sync scenarios (main branch only)

> **CI migration (Phase 1):** Update `ci.yml` to build Elixir release, run `mix test`, then existing integration + E2E tests (language-agnostic, no changes needed). Add `mix format --check-formatted` and `mix credo` for code quality. Dialyzer optional (slow, add later).

## Production Deployment (SaaS — Fly.io + Phoenix)

### SaaS Infrastructure

| Service | Provider | Purpose | Cost |
|---------|----------|---------|------|
| **Compute** | Fly.io Machines | Phoenix app (Elixir release), shared-cpu-1x 1GB | ~$5-7/mo |
| **PostgreSQL** | Fly Postgres | Notes, auth, RLS tenant isolation, Oban job queue | ~$7/mo single node |
| **Vector DB** | Qdrant Cloud | Embedding vectors | Free tier (1GB) to start |
| **Embeddings** | Voyage AI API | `voyage-4-large`, 1024d | $0.06/M tokens |
| **Attachments** | Fly Tigris | S3-compatible object storage (via ExAws) | $0.02/GB/mo |
| **Observability** | PromEx + Sentry | Auto-instrumented Phoenix/Ecto/Oban/BEAM metrics + error tracking | Free tiers |
| **Reranker** | None (planned) | — | — |
| **Redis** | Not needed | PubSub via Erlang clustering, caching via ETS | $0 |
| **Clustering** | dns_cluster | Auto node discovery via `.internal` DNS | Built-in |

### Deploy Process (Fly.io)

```bash
# First deploy (auto-detects Phoenix, generates Dockerfile + fly.toml + clustering config)
fly launch
fly postgres create --name engram-db
fly postgres attach --app engram engram-db
fly storage create --name engram-attachments   # Tigris bucket
fly secrets set VOYAGE_API_KEY=... QDRANT_URL=... QDRANT_API_KEY=... JWT_SECRET=... RELEASE_COOKIE=...
fly deploy

# Subsequent deploys (runs Ecto migrations via release_command, then rolling deploy)
fly deploy

# Manual operations
fly logs                           # View logs
fly ssh console                    # SSH into container
fly postgres connect -a engram-db  # SQL access
fly status                         # Check health

# IEx remote shell into running Fly machine
fly ssh console --pty -C "/app/bin/engram remote"
```

**Fly.io Phoenix specifics:**
- `fly launch` runs `mix phx.gen.release --docker` and appends IPv6 config
- `release_command = "/app/bin/migrate"` runs Ecto migrations before each deploy
- `dns_cluster` auto-clusters machines via Fly's `.internal` DNS (AAAA records)
- PgBouncer (Fly Postgres default) uses transaction mode — fine for Ecto, no LISTEN/NOTIFY needed
- `RELEASE_COOKIE` must be pinned as a Fly secret (Docker rebuilds randomize it otherwise)
- WebSocket connections handled natively by Fly's proxy (TLS terminated at edge)

### Local Docker Compose (Dev / CI)

> **Note:** Self-hosted deployment is deferred. Launch is SaaS-only. This Docker setup is for local development and CI testing only. See `docs/context/pricing-strategy.md`.

```bash
docker compose up --build    # Elixir app + PostgreSQL + Qdrant (local dev)
```

Stack: `engram` (Elixir), `engram-postgres`, `qdrant`, optionally `ollama` (GPU) and `jina-reranker`.

### Backups (Decided 2026-04-02)

**Current plan:** Fly Postgres automatic daily volume snapshots (free, included). RPO: up to 24 hours of data loss in worst case.

**Restore procedure:**
```bash
fly volumes list -a engram-db          # find volume ID
fly volumes snapshots list <vol_id>    # list available snapshots
fly postgres failover -a engram-db     # restore from snapshot (creates new machine)
```

**Future (when revenue justifies):**
- **WAL-based PITR** — continuous WAL archival to Tigris via `wal-g`, minutes RPO (~$1/mo storage)
- **Standby replica** — streaming replication to second Fly machine, seconds RPO (~$7/mo)

**Qdrant Cloud:** Has its own backup/snapshot system. Free tier includes daily snapshots. For SaaS, Qdrant data is reconstructable from Postgres (re-embed all notes), so Qdrant backups are convenience, not critical.

### Observability (Decided 2026-04-02)

**Stack:** PromEx (auto-instrumentation) + Sentry (error tracking). Both have free tiers.

**PromEx** (`prom_ex` hex package) auto-instruments:
- **Phoenix** — request latency/count by endpoint, WebSocket connection count
- **Ecto** — query duration, pool checkout time
- **Oban** — job duration, queue depth, failure rate, retry count (critical for embedding pipeline health)
- **BEAM** — scheduler utilization, memory, process count, GC stats

**Sentry** (`sentry` hex package):
- Captures unhandled exceptions with full stack traces
- Oban job failures automatically reported
- Phoenix error responses (500s) captured with request context

**Configuration:**
```elixir
# config/runtime.exs
config :sentry,
  dsn: System.get_env("SENTRY_DSN"),
  environment_name: config_env(),
  enable_source_code_context: true

# lib/engram/prom_ex.ex
defmodule Engram.PromEx do
  use PromEx, otp_app: :engram
  @impl true
  def plugins do
    [
      PromEx.Plugins.Phoenix,
      PromEx.Plugins.Ecto,
      PromEx.Plugins.Oban,
      PromEx.Plugins.Beam,
      PromEx.Plugins.Application
    ]
  end
end
```

**Future:** Add Grafana Cloud (free tier, 10K metrics, 14-day retention) for dashboards and alerting when there are paying users to monitor.

### Data Migration Strategy (Decided 2026-04-02)

**Decision:** Fresh launch. No data migration from the Python backend. The Elixir rewrite is a clean start.

- No existing production users with data that needs preserving
- Python database schema is close but not identical (missing RLS, chunks table, some indexes)
- Integration tests (`test_plan.sh`) and E2E tests are language-agnostic — they validate the Elixir backend produces identical API behavior
- If needed later, a one-time migration script can export Python Postgres → import to Elixir Postgres (same core schema)

### Security Hardening (Open — Needs Design)

Items identified during audit that need decisions before production launch:

| Item | Status | Notes |
|------|--------|-------|
| **CORS policy** | TODO | Allow plugin origin (`app://obsidian.md`) + configured domains. Block browser-based cross-origin attacks. |
| **CSP headers** | TODO | Restrictive policy for web UI pages. Not needed for API-only endpoints. |
| **Request body size limit** | TODO | 10MB max (matches `MAX_NOTE_SIZE`). Phoenix default is 8MB. |
| **WebSocket origin check** | TODO | Phoenix `check_origin` config. Validate on socket connect. |
| **WebSocket message rate limit** | TODO | Hammer check in Channel `handle_in`. Prevents flooding. ~60 msgs/min per connection. |
| **API key revocation** | TODO | `DELETE /api-keys/{id}` exists. Need immediate ETS cache invalidation on revoke. |
| **Secret rotation procedure** | TODO | Document: generate new → set as Fly secret → deploy → old JWT sessions expire (7-day). |
| **TLS** | Done | Fly.io terminates TLS at edge automatically. No app-level config needed. |
| **Quota enforcement** | TODO — Deep dive | **Requires dedicated design session.** Key product-tier differentiator. Must answer: where to enforce (Plug vs context vs both), how to calculate (per-request vs periodic), what happens mid-sync when limit hit (reject? queue? grace period?), per-tier limits (Base vs Pro), attachment vs note quotas, metering for billing. Blocked on Phase 10 (Billing) decisions. |

## Elixir Migration Plan

Rewriting Engram from Python/FastAPI to Elixir/Phoenix. This section captures all decisions and required work so it can be picked up cold.

### Decision Audit (2026-04-02)

| Area | Decision | Rationale |
|------|----------|-----------|
| **Language** | Python/FastAPI → **Elixir/Phoenix** | BEAM VM purpose-built for massive concurrent connections, OTP supervision trees for self-healing, Phoenix Channels for bidirectional real-time sync |
| **Real-time** | SSE + PG LISTEN/NOTIFY → **Phoenix Channels (WebSocket)** | Bidirectional, built-in presence tracking, cluster-native PubSub, no reconnect hacks |
| **Multi-tenancy** | App-level user_id filtering → **PostgreSQL RLS + tenant_id** | DB-enforced isolation via `SET LOCAL` per transaction, fail-closed (no tenant = no rows), defense-in-depth |
| **DB roles** | Single role → **Two roles** | `engram_owner` (migrations, bypasses RLS) + `engram_app` (runtime, subject to RLS) |
| **Clustering** | None (single instance) → **dns_cluster** | Auto node discovery via Fly's `.internal` DNS, enables distributed PubSub |
| **PubSub** | PostgreSQL LISTEN/NOTIFY + Redis → **Phoenix.PubSub.PG2** | Native Erlang distribution, cross-region broadcast, no Redis needed |
| **Caching** | Redis → **ETS** (Erlang Term Storage) | In-process, clustered via PubSub if needed, eliminates Redis dependency |
| **Rate limiting** | Custom Python + Redis → **Hammer** | Token bucket, ETS or Redis backend, Plug integration |
| **Auth: JWT** | PyJWT → **Joken** | Lightweight, Plug-native |
| **Auth: API keys** | SHA256 hash + custom cache → **Same pattern**, ETS cache | Same security model, faster in-process caching |
| **S3 client** | boto3 → **ExAws + ExAws.S3** | Battle-tested, Tigris-compatible, official Fly docs |
| **Qdrant client** | qdrant-client (Python SDK) → **Custom Req HTTP wrapper** (~150 LOC) | No official Elixir SDK; REST API is simple, thin wrapper sufficient |
| **Embeddings** | httpx → **Req HTTP wrapper** (~30 LOC) | Same Voyage AI REST API, just different HTTP client |
| **Markdown parsing** | Custom Python parser → **Earmark AST + custom walker** | Earmark provides full AST, chunking logic reimplemented (~150 LOC) |
| **MCP server** | Python FastMCP → **Hermes MCP** (Elixir) | Young but functional, working production examples exist |
| **Job queue** | None (synchronous indexing) → **Oban** (PostgreSQL-backed) | Durable jobs survive crashes/deploys, built-in retry/backoff/dedup/rate-limiting, no new infra (uses existing Postgres) |
| **Password hashing** | bcrypt (Python) → **Argon2** (argon2_elixir) | OWASP recommended, memory-hard (resists GPU attacks), Comeonin integration |
| **Testing** | pytest → **ExUnit + ExMachina + Mox + Bypass** | `async: true` parallel tests, Ecto.Sandbox per-test transactions |
| **Deployment** | Docker + custom deploy.sh → **`fly launch` (auto-detects Phoenix)** | Generates Dockerfile, fly.toml, clustering config automatically |
| **Observability** | None → **PromEx + Sentry** | PromEx auto-instruments Phoenix/Ecto/Oban/BEAM metrics; Sentry captures errors with stack traces. Both free tier. |
| **Backups** | None → **Fly volume snapshots** (daily, free) | Sufficient for launch. WAL-based PITR when revenue justifies. Qdrant data is reconstructable from Postgres. |
| **Data migration** | N/A → **Fresh launch** | No existing users. Integration + E2E tests validate API parity. One-time script if needed later. |
| **RLS enforcement** | Trust-based → **Layered defense** | Process-dict guard in `Repo.prepare_query` raises on unscoped tenant queries. Safe with PgBouncer transaction mode + Ecto.Sandbox. |
| **IDs** | BIGSERIAL exposed in API → **BIGSERIAL internal only** | API uses `path` as identifier. Numeric IDs never in responses. Add `public_id UUID` column if share links needed later. |
| **App structure** | Single OTP app | No umbrella. Single app is simpler at this scale. Split indexing into separate app only if deployment topology requires it. |
| **Supervision** | Default Phoenix → **one_for_one** | Independent worker processes. Channel crashes don't affect Oban, Oban crashes don't affect Channels. Standard Phoenix defaults with Oban supervisor added to application children. |
| **Self-hosted embedding** | Ollama or voyage-4-nano → **Ollama only** | voyage-4-nano requires Voyage API key, contradicts "free, user's own infra." Ollama is truly local. |
| **MCP fallback** | Hermes MCP (primary) | If Hermes abandoned: raw JSON-RPC stdio server (~200 LOC). MCP protocol is simple. Monitor Hermes activity quarterly. |
| **Tokenizer for chunking** | Approximate word-based (~4 chars/token) | Voyage handles actual tokenization. 512 "tokens" is a soft target. Exact sizing benchmarked in Priority 4. |
| **Email** | None for launch | API key auth doesn't need email verification. Add Swoosh for password reset when there are paying users. Manual admin reset until then. |
| **Billing** | None for launch (future Phase 10) | Stripe integration after core product works. Quota enforcement designed separately. |
| **Load testing** | Deferred to Phase 9 (Deploy) | Key questions: WebSocket connections/machine, embedding throughput, Voyage rate ceiling impact on bulk operations. |

### Decisions Unchanged

| Area | Decision | Details |
|------|----------|---------|
| **Embedding provider** | Voyage AI `voyage-4-large` (1024d, $0.06/M tokens) | Top MTEB, shared space with nano, matryoshka support |
| **Vector DB** | Qdrant Cloud (free tier 1GB) | Same provider, REST API access |
| **Compute** | Fly.io | Now with first-class Phoenix support |
| **Database** | Fly Postgres | Same provider, now with RLS policies |
| **Attachments** | Fly Tigris (S3) | Same provider, ExAws client instead of boto3 |
| **No reranker** | Vector-only search to start | Will benchmark Voyage Rerank 2.5 vs Jina later |
| **Dimensions** | 1024d (Voyage default) | Benchmark 512d later via matryoshka |

### Chunking & Retrieval Strategy (Decided 2026-04-02)

**Current state:** heading-aware chunking at ~512 tokens / 50 overlap (approximate, word-based ~4 chars/token — Voyage API handles actual tokenization). Raw chunk text embedded without context. Vector-only search.

**Decided approach (layered, each independent):**

| Priority | Strategy | What Changes | Elixir Module |
|----------|---------|-------------|---------------|
| **1** | **Folder-aware context prepending** | Prepend `folder_path > title > heading` to chunk text before embedding. ~35% retrieval failure reduction (Anthropic benchmark). | `Engram.Indexing` |
| **2** | **Structure preservation** | Keep code blocks, bullet lists, and markdown tables as atomic units — never split mid-block. | `Engram.Parsers.Markdown` |
| **3** | **BM25 hybrid search** | Add sparse vectors (Qdrant native) alongside dense vectors. Reciprocal rank fusion. | `Engram.Search`, `Engram.Vector.Qdrant` |
| **4** | **Chunk size benchmarking** | Test 256 vs 512 vs 1024 on real data. | `Engram.Parsers.Markdown` |
| **5** | **Parent-child retrieval** | Small chunks for precision, return parent section for context. | `Engram.Search`, `Engram.Vector.Qdrant` |

**Rejected strategies:**
- **Semantic chunking** — NAACL 2025 shows fixed-size matches or beats it. Heading structure provides natural boundaries. Extra embedding cost.
- **voyage-context-3** — Voyage 3 gen, incompatible with Voyage 4 shared space, 50% more expensive, kills tiered product.
- **Late chunking (Jina)** — Requires Jina-specific models, incompatible with Voyage.
- **LLM-based chunking** — $50-$1,250 to re-index 5K notes. Every edit triggers LLM calls.

**Folder-aware context format:**
```
Knowledge > Health > Blood Work | Iron Panel > Ferritin

Ferritin levels between 30-300 ng/mL are considered normal...
```

### Async Indexing Pipeline (Oban — Decided 2026-04-02)

**Problem:** Embedding involves external API calls (Voyage AI, Qdrant) that can fail, take seconds, and cost money. Running them synchronously in the request path blocks the response, wastes API calls on rapid edits, and has no retry mechanism if Voyage AI is down.

**Decision:** All RAG work (parse → embed → Qdrant upsert) runs asynchronously via Oban. Note sync (device ↔ server) remains synchronous and immediate. The API returns as soon as the note is persisted to Postgres and the sync broadcast is sent.

**Why Oban over Kafka/RabbitMQ:** Oban uses the existing PostgreSQL database — no new infrastructure, no new failure mode, no additional cost. Kafka and RabbitMQ solve cross-service event routing at massive scale; Engram is a single OTP app where the web endpoint hands off work to a background processor. Oban is purpose-built for this. Jobs are Postgres rows — they survive app crashes, deploys, and restarts.

#### Request Flow (after migration)

```
POST /notes
  → Persist to PostgreSQL (immediate, in request)
  → Compute content_hash — if unchanged from previous, skip Oban job
  → Increment version
  → Broadcast via PubSub to all connected devices (immediate)
  → Oban.insert(EmbedNoteWorker, %{note_id: id}, unique/replace opts)
  → Return 200 with note metadata + "indexing": "queued"

[Oban worker picks up job — 5s debounce]
  → Fetch CURRENT note content from DB (not from job args — always latest)
  → Parse markdown → chunks (Earmark AST)
  → Contextualize (prepend folder > title > heading)
  → Batch embed via Voyage AI (all chunks in one API call, up to 128 texts)
  → Delete old chunks (Postgres + Qdrant) for this note
  → Insert new chunks (Postgres metadata + Qdrant vectors)
  → On failure: retry with backoff (see schedule below)
```

#### Oban Queues

| Queue | Concurrency | Rate Limit | Purpose |
|-------|------------|------------|---------|
| `embed` | 5 | 100/min (Voyage API ceiling) | Per-note embedding after upsert |
| `reindex` | 1 | 10/min | Bulk re-embedding (model migration, context format change) |
| `maintenance` | 2 | — | Soft-delete purge, stale job cleanup, orphan chunk detection |

#### Deduplication & Debouncing

**Problem:** A user edits a note 10 times in 30 seconds. Without dedup, 10 embedding jobs run (10x API cost, 10x Qdrant writes).

**Solution:** Oban's `unique` + `replace` options:

```elixir
defmodule Engram.Workers.EmbedNote do
  use Oban.Worker,
    queue: :embed,
    max_attempts: 5,
    unique: [
      period: 60,                          # dedup window
      keys: [:note_id],                    # one job per note
      states: [:available, :scheduled]     # don't dedup if already executing
    ]

  @impl true
  def perform(%Job{args: %{"note_id" => note_id}}) do
    # Always fetch CURRENT content from DB — not from job args.
    # This means even if queued 30s ago and note was edited since,
    # we embed the latest version.
    note = Repo.get!(Note, note_id)
    # ... parse, embed, upsert
  end
end

# Called from NoteController:
Oban.insert(EmbedNote.new(
  %{note_id: note.id},
  scheduled_at: DateTime.add(DateTime.utc_now(), 5, :second),  # 5s debounce
  replace: [:scheduled_at]  # reset debounce timer on re-insert
))
```

**How this works for 10 rapid edits:**
1. Edit 1 → INSERT job (note_id=42, scheduled_at=now+5s)
2. Edit 2 → REPLACE job (note_id=42, scheduled_at=now+5s) — timer reset
3. ...edits 3-10 → each REPLACE resets the timer
4. 5 seconds after the LAST edit → ONE job runs, fetches latest content from DB
5. **Result:** 1 Voyage API call instead of 10. 90% cost savings.

**Content hash skip:** Before inserting the Oban job, the controller computes `SHA256(content)` and compares to `notes.content_hash`. If identical (e.g., metadata-only change from a rename), no embedding job is created at all.

#### Retry & Failure Strategy

| Attempt | Backoff | What happens |
|---------|---------|-------------|
| 1 | Immediate (after 5s debounce) | Normal execution |
| 2 | 30 seconds | Voyage API might be rate-limited |
| 3 | 2 minutes | Transient outage |
| 4 | 15 minutes | Extended outage |
| 5 | 1 hour | Last attempt |
| Exhausted | Move to `discarded` | Note is stored but not searchable |

**Discarded job recovery:** A daily Oban cron job (`maintenance` queue) scans for `discarded` embed jobs and re-enqueues them. This catches notes that failed during a Voyage AI outage.

**Crash safety:** If the BEAM process crashes mid-embedding, Oban's `rescue_orphaned_jobs` plugin detects jobs stuck in `executing` state (no heartbeat for 60s) and moves them back to `available` for retry. No manual intervention needed.

#### Backpressure

- **Oban concurrency limit** — `embed` queue runs max 5 concurrent workers. If 500 notes are pushed at once, they queue up and process 5 at a time.
- **Voyage AI rate limiting** — Oban's `rate_limit` option caps at 100 jobs/min per queue, matching Voyage API ceilings.
- **Qdrant writes** — each embed job does one batch upsert per note (not per chunk), so Qdrant write pressure scales with notes, not chunks.
- **Memory** — workers fetch one note at a time from DB; no risk of loading 500 notes into memory simultaneously.

#### Scheduled Jobs (Cron)

```elixir
config :engram, Oban,
  queues: [embed: 5, reindex: 1, maintenance: 2],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 7 * 24 * 3600},  # prune completed jobs after 7 days
    Oban.Plugins.Lifeline,                             # rescue orphaned jobs
    {Oban.Plugins.Cron, crontab: [
      {"0 3 * * *", Engram.Workers.PurgeSoftDeletes},  # daily at 3am: hard-delete notes with deleted_at > 30 days
      {"0 4 * * *", Engram.Workers.RetryDiscarded},     # daily at 4am: re-enqueue discarded embed jobs
      {"0 5 * * 0", Engram.Workers.OrphanChunkScan},    # weekly: find Qdrant points with no matching chunks row
    ]}
  ]
```

### Phoenix Channel Event Contract (Decided 2026-04-02)

Replaces SSE (`GET /notes/stream`). The plugin connects via WebSocket and joins a per-user channel. All sync events flow through this channel.

#### Connection & Auth

```
WebSocket connect: wss://engram.fly.dev/socket/websocket?token=<api_key>
  → Socket.connect/3 validates Bearer token, assigns user_id
  → Client joins topic "sync:{user_id}"
  → Channel.join/3 verifies user_id matches socket assignment
  → Presence tracks device (device_id from join params)
```

#### Client → Server Events

| Event | Payload | Server Response | Purpose |
|-------|---------|-----------------|---------|
| `push_note` | `{path, content, mtime, version?}` | `{note: {...}, indexing: "queued"}` or `{conflict: true, server_note: {...}}` | Push local change (same contract as POST /notes) |
| `delete_note` | `{path}` | `{ok: true}` | Soft-delete (same as DELETE /notes/{path}) |
| `rename_note` | `{old_path, new_path}` | `{note: {...}}` | Rename (same as POST /notes/rename) |
| `pull_changes` | `{since: ISO8601}` | `{changes: [...], server_time: ISO8601}` | Pull changes since timestamp |
| `push_attachment` | `{path, content_base64, mime_type, mtime}` | `{attachment: {...}}` | Push attachment |

#### Server → Client Broadcasts

| Event | Payload | When | Purpose |
|-------|---------|------|---------|
| `note_changed` | `{event_type: "upsert"\|"delete", path, timestamp, kind: "note"\|"attachment"}` | After any note/attachment mutation by ANY device | Real-time sync notification (same as SSE `note_change`) |
| `presence_state` | `{devices: [{device_id, joined_at}]}` | On join | Current connected devices for this user |
| `presence_diff` | `{joins: [...], leaves: [...]}` | On device connect/disconnect | Device change notification |

#### Echo Suppression

The server does NOT broadcast `note_changed` back to the device that originated the change. Phoenix Channels supports this via `broadcast_from/3` (broadcasts to all *except* the sender). The plugin's existing 5-second echo cooldown remains as a safety net for edge cases (e.g., two rapid pushes where the broadcast from push 1 arrives after push 2 starts).

#### Conflict Flow (over WebSocket)

```
Client sends: push_note {path: "Health/Labs.md", content: "...", version: 3}
Server checks: notes.version for this path

If version matches (3 == 3):
  → Upsert, increment to version 4
  → Reply: {note: {..., version: 4}, indexing: "queued"}
  → broadcast_from: note_changed {path, event_type: "upsert", ...}

If version mismatch (3 != 5):
  → Reply: {conflict: true, server_note: {content: "...", version: 5}}
  → Client performs 3-way merge (base from BaseStore + local + server_note.content)
  → If clean merge: client sends push_note again with merged content + version: 5
  → If conflicts: client shows ConflictModal, user resolves, then push
```

#### Migration from SSE

| SSE (Python, current) | Channel (Elixir, target) |
|------------------------|--------------------------|
| `GET /notes/stream` (one-way) | `join "sync:{user_id}"` (bidirectional) |
| `event: connected` | `phx_reply` on successful join |
| `event: note_change` | server broadcast `note_changed` |
| Polling for push (`POST /notes` separate) | `push_note` event on same connection |
| No presence | `presence_state` + `presence_diff` |
| Reconnect with exponential backoff | Phoenix.js auto-reconnect with backoff (built-in) |

**Plugin migration:** The plugin's `NoteStream` class (SSE) is replaced by a Phoenix Channel client. The `SyncEngine` calls change from `this.api.pushNote()` (HTTP) + `this.stream.onEvent` (SSE) to `this.channel.push("push_note", ...)` + `this.channel.on("note_changed", ...)`. The conflict resolution and 3-way merge logic is unchanged — only the transport layer changes.

### Database Schema (with RLS)

```sql
-- Tables (same structure, RLS enforced)
CREATE TABLE notes (
  id BIGSERIAL PRIMARY KEY,
  user_id BIGINT NOT NULL REFERENCES users(id),
  path TEXT NOT NULL,
  title TEXT,
  content TEXT,
  folder TEXT,
  tags TEXT[],
  version INTEGER NOT NULL DEFAULT 1,       -- monotonic, incremented on every upsert (optimistic concurrency)
  content_hash TEXT,                         -- SHA256 of content, enables skip-if-unchanged during sync
  mtime DOUBLE PRECISION,
  deleted_at TIMESTAMPTZ,
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(user_id, path)
);

-- Chunk metadata (source of truth for what chunks exist; vectors + raw text live in Qdrant)
CREATE TABLE chunks (
  id BIGSERIAL PRIMARY KEY,
  note_id BIGINT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
  user_id BIGINT NOT NULL REFERENCES users(id),
  position SMALLINT NOT NULL,               -- chunk order within note (0-indexed)
  heading_path TEXT,                         -- e.g., "## Benefits > ### Omega-3"
  char_start INTEGER NOT NULL,              -- start offset in note content
  char_end INTEGER NOT NULL,                -- end offset in note content
  qdrant_point_id UUID NOT NULL,            -- reference to Qdrant vector point
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(note_id, position)
);

CREATE TABLE attachments (
  id BIGSERIAL PRIMARY KEY,
  user_id BIGINT NOT NULL REFERENCES users(id),
  path TEXT NOT NULL,
  mime_type TEXT,
  size_bytes BIGINT,
  mtime DOUBLE PRECISION,
  deleted_at TIMESTAMPTZ,
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(user_id, path)
  -- content stored in Tigris (SaaS) or local filesystem (self-hosted), NOT in DB
);

CREATE TABLE users (
  id BIGSERIAL PRIMARY KEY,
  email TEXT UNIQUE NOT NULL,
  password_hash TEXT NOT NULL,  -- Argon2id via argon2_elixir/Comeonin
  display_name TEXT,
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE api_keys (
  id BIGSERIAL PRIMARY KEY,
  user_id BIGINT NOT NULL REFERENCES users(id),
  key_hash TEXT NOT NULL,  -- SHA256 of raw key, raw never stored
  name TEXT,
  last_used TIMESTAMPTZ,
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes (beyond UNIQUE constraints)
CREATE INDEX idx_notes_user_updated ON notes(user_id, updated_at);    -- changes-since query
CREATE INDEX idx_notes_user_folder ON notes(user_id, folder);          -- folder listing
CREATE INDEX idx_notes_user_deleted ON notes(user_id, deleted_at)
  WHERE deleted_at IS NOT NULL;                                        -- soft-delete cleanup
CREATE INDEX idx_chunks_note ON chunks(note_id);                       -- chunk lookup by note
CREATE INDEX idx_api_keys_hash ON api_keys(key_hash);                  -- auth lookup

-- RLS policies (applied to all tenant-scoped tables)
ALTER TABLE notes ENABLE ROW LEVEL SECURITY;
ALTER TABLE notes FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation_notes ON notes
  USING (user_id::text = current_setting('app.current_tenant', true))
  WITH CHECK (user_id::text = current_setting('app.current_tenant', true));

-- Repeat for attachments, api_keys, chunks

-- Roles
CREATE ROLE engram_app NOINHERIT;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO engram_app;
-- App connects as engram_app (subject to RLS)
-- Migrations connect as engram_owner (bypasses RLS)
```

**Sync versioning:** The `version` column is a server-controlled monotonic counter, incremented on every upsert. The plugin sends its known `version` on push; if the server's version doesn't match, the server returns 409 with the current note state. The plugin then attempts 3-way merge (base from `BaseStore` + local + remote). `content_hash` (SHA256) enables the server to skip re-indexing when content hasn't actually changed (e.g., metadata-only updates).

**Chunk storage (hybrid):** Postgres `chunks` table is the source of truth for what chunks exist and their positions within a note. Qdrant stores the actual vectors + contextualized text for search. On re-index: delete all chunks for note_id from both Postgres and Qdrant, then re-parse and re-insert. This enables parent-child retrieval (Priority 5) — fetch matching chunk from Qdrant, look up sibling chunks from Postgres, return the full section.

**IDs:** BIGSERIAL is used for internal foreign keys and joins. Numeric IDs are NOT exposed in API responses — the API uses `path` as the primary identifier (all endpoints are `/notes/{path}`, not `/notes/{id}`). If public-facing IDs are needed later (e.g., share links), add a `public_id UUID` column rather than changing primary keys.

**Ecto integration — RLS Enforcement Strategy (Decided 2026-04-02):**

The RLS system has a subtle failure mode: if any code path queries a tenant-scoped table without calling `with_tenant/2`, `current_setting('app.current_tenant', true)` returns `''`, and RLS silently returns zero rows. No crash, no error — just missing data. This requires a layered defense:

```elixir
defmodule Engram.Repo do
  use Ecto.Repo, otp_app: :engram

  # Layer 1: Tenant-scoped transaction wrapper
  # Every tenant query MUST go through this. Sets both the process-dict
  # guard (fast, for prepare_query) and the PostgreSQL SET LOCAL (for RLS).
  def with_tenant(tenant_id, fun) do
    Process.put(:engram_tenant, tenant_id)
    try do
      transaction(fn ->
        query!("SET LOCAL app.current_tenant = $1", [to_string(tenant_id)])
        fun.()
      end)
    after
      Process.delete(:engram_tenant)
    end
  end

  # Layer 2: Safety net — raises if tenant-scoped table queried without context
  # Uses process dict (zero-cost check) rather than an extra SQL query.
  @tenant_tables ~w(notes chunks attachments api_keys)a

  @impl true
  def prepare_query(_operation, query, opts) do
    if tenant_required?(query) and is_nil(Process.get(:engram_tenant))
       and not Keyword.get(opts, :skip_tenant_check, false) do
      raise Engram.TenantError,
        "Tenant context not set! Use Repo.with_tenant/2 for tenant-scoped queries."
    end
    {query, opts}
  end

  defp tenant_required?(query) do
    # Check if query targets a tenant-scoped table
    # Implementation: inspect the Ecto.Query source and match against @tenant_tables
  end
end
```

**Enforcement layers:**

| Layer | Where | What | Failure mode |
|-------|-------|------|-------------|
| **Auth Plug** | HTTP requests | Extracts `user_id` from Bearer token → `conn.assigns.user_id` | 401 if missing |
| **Socket.connect** | WebSocket | Extracts `user_id` from token → `socket.assigns.user_id` | Connection refused |
| **Context functions** | `Notes`, `Search`, etc. | Receive `user_id` as parameter, always call `Repo.with_tenant/2` | Compile-time pattern — all public context functions take `user_id` |
| **Oban workers** | Background jobs | Receive `user_id` in job args, call `Repo.with_tenant/2` | Job fails → Oban retries |
| **Repo.prepare_query** | Every DB query | Raises if tenant-scoped table queried without process-dict guard | Crash in dev/test, logged alert in prod |

**PgBouncer safety:** `SET LOCAL` is scoped to the explicit transaction inside `with_tenant/2`. When the transaction ends, the setting disappears. PgBouncer (transaction mode) returns a clean connection to the pool. No tenant leakage between requests. This is safe because `with_tenant/2` always wraps queries in `Repo.transaction/1` — there are no "bare" queries against tenant tables.

**`skip_tenant_check` escape hatch:** For the rare cases where you need to query across tenants (admin dashboard, cron cleanup jobs), pass `skip_tenant_check: true` in query opts. These queries run as `engram_owner` (bypasses RLS) or use explicit `WHERE user_id = ?` filtering. Usage of this flag should be audited in code review.

**Testing RLS with Ecto.Sandbox:**

Ecto.Sandbox wraps each test in a transaction that rolls back after the test. `SET LOCAL` inside nested `with_tenant/2` calls creates savepoints within the sandbox transaction — the tenant setting is respected correctly.

```elixir
# Phase 1 spike test — must pass before building on RLS
test "tenant isolation via RLS" do
  user_a = insert(:user)
  user_b = insert(:user)

  # Insert as User A
  {:ok, _} = Repo.with_tenant(user_a.id, fn ->
    Repo.insert!(%Note{user_id: user_a.id, path: "secret.md", content: "private"})
  end)

  # User B cannot see User A's notes
  {:ok, notes} = Repo.with_tenant(user_b.id, fn ->
    Repo.all(Note)
  end)
  assert notes == []

  # Query without tenant context raises
  assert_raise Engram.TenantError, fn ->
    Repo.all(Note)
  end
end
```

If this pattern fails with Ecto.Sandbox (unlikely but possible with certain Sandbox modes), fallback is `:manual` checkout mode with explicit connection management per tenant.

### Elixir Library Dependencies

| Library | Version | Purpose | Maturity |
|---------|---------|---------|----------|
| **Phoenix** | 1.8+ | Web framework, Channels, PubSub | Production |
| **Ecto** | 3.12+ | Database layer, migrations, schemas | Production |
| **Oban** | 2.18+ | PostgreSQL-backed job queue (embedding pipeline, re-indexing, maintenance) | Production |
| **Joken** | 2.6+ | JWT sign/verify | Production |
| **argon2_elixir** | 4.1+ | Password hashing (Argon2id via Comeonin) | Production |
| **ExAws** + **ExAws.S3** | 2.6+ | S3 client for Tigris | Production |
| **Hammer** | 6.1+ | Rate limiting (token bucket) | Production |
| **Redix** | 1.2+ | Redis client (optional, only if needed) | Production |
| **Earmark** | 1.4+ | Markdown → AST parsing | Production |
| **Req** | 0.5+ | HTTP client (Qdrant, Voyage AI) | Production |
| **Hermes MCP** | latest | MCP server protocol (fallback: raw JSON-RPC stdio ~200 LOC) | Early |
| **PromEx** | 1.9+ | Auto-instrumented Prometheus metrics (Phoenix, Ecto, Oban, BEAM) | Production |
| **Sentry** | 10.0+ | Error tracking, exception capture with stack traces | Production |
| **dns_cluster** | 0.1+ | Fly.io node discovery | Production |
| **ExMachina** | dev | Test factories | Production |
| **Mox** | dev | Behaviour-based mocks | Production |
| **Bypass** | dev | HTTP mock server | Production |

### Build Phases

| Phase | What | Acceptance Criteria |
|-------|------|---------------------|
| **1: Scaffold** | Phoenix app, Ecto schemas, RLS migrations, auth (JWT + API keys + Argon2), health endpoints, Repo.with_tenant + prepare_query safety net, Oban setup | `GET /health` returns 200, user registration + login works, RLS spike test passes (tenant isolation + prepare_query raises on unscoped query), Oban processes a test job |
| **2: Notes CRUD** | Note upsert/read/delete/rename/changes endpoints, path sanitization | `test_plan.sh` note CRUD tests pass |
| **3: Indexing** | Markdown parser (Earmark), Voyage embedder, Qdrant client, indexing pipeline | Note upsert triggers embedding + Qdrant upsert |
| **4: Search** | Vector search, folder filter, tag filter | `test_plan.sh` search tests pass |
| **5: Real-time** | Phoenix Channel for sync, Presence for device tracking | E2E sync tests pass (push/pull/conflict/multi-device) |
| **6: Attachments** | Tigris S3 upload/download via ExAws | `test_plan.sh` attachment tests pass |
| **7: MCP** | MCP server via Hermes MCP | MCP tools work from Claude/Cursor |
| **8: Web UI** | Phoenix LiveView or templates for login, search, logs | Web UI functional |
| **9: Deploy** | Fly.io deployment, dns_cluster, production config, CI pipeline (Elixir), load testing | `fly deploy` succeeds, all E2E tests pass against Fly, CI runs `mix test` + integration + E2E, load test establishes WebSocket connection ceiling and embedding throughput |
| **10: Billing** *(future)* | Stripe integration, subscription management, quota enforcement, usage metering | Users can subscribe, upgrade, downgrade. Quotas enforced per tier. |

### Development Environment

**Local dev on FastRaid (Docker):**
- Elixir app runs in Docker container on FastRaid
- Connects to **real** Voyage AI API (not mocked)
- Connects to **real** Qdrant Cloud (not local)
- Connects to **real** Tigris (not local S3)
- PostgreSQL in Docker (local, with RLS policies)
- This ensures adapters are validated against real services from day 1

**Why Docker on FastRaid:** FastRaid is the dev VM with GPU (for Ollama self-hosted testing). Docker provides consistent Elixir environment without installing Elixir system-wide.

### Infrastructure Setup

| # | Action | Command / Steps | Status |
|---|--------|-----------------|--------|
| 1 | Create Fly app | `fly launch --name engram` (auto-detects Phoenix) | TODO |
| 2 | Create Fly Postgres | `fly postgres create --name engram-db` | TODO |
| 3 | Attach Postgres | `fly postgres attach --app engram engram-db` | TODO |
| 4 | Create Tigris bucket | `fly storage create --name engram-attachments` | TODO |
| 5 | Qdrant Cloud cluster | Create at qdrant.tech (free tier, 1GB RAM) | TODO |
| 6 | Voyage AI API key | Get at voyageai.com | TODO |
| 7 | Set secrets | `fly secrets set VOYAGE_API_KEY=... QDRANT_URL=... QDRANT_API_KEY=... JWT_SECRET=... RELEASE_COOKIE=...` | TODO |
| 8 | Deploy | `fly deploy` | TODO |
| 9 | Verify | `curl https://engram.fly.dev/health/deep` | TODO |

### Re-indexing & Embedding Migration (future)

Re-indexing is needed when **any** of these change: embedding model, context format (folder prepending), chunk size, or structure preservation rules. All trigger the same blue-green workflow.

**Triggers requiring full re-index:**
- Model change (e.g., Voyage 4 → Voyage 5) — different vector space
- Context format change (e.g., adding folder-aware prepending) — same model, different input text
- Chunk size change (e.g., 512 → 1024 tokens) — different chunk boundaries
- Multimodal upgrade (voyage-multimodal-3.5) — different vector space

**Blue-green strategy:**
1. Create second Qdrant collection (`obsidian_notes_v2`)
2. Oban `reindex` queue processes all notes (low priority, max concurrency 1)
3. Each note: re-parse → re-contextualize → re-embed → upsert to v2 collection + update Postgres `chunks`
4. When complete: swap `QDRANT_COLLECTION` pointer to v2, delete v1
5. Zero downtime — search uses whichever collection the pointer references

**Cost:** ~$225 at 5K users for full re-embed (Voyage API). Trivial.

**Implementation:** Re-indexing runs via `Engram.Workers.ReindexAll` Oban worker on the `reindex` queue. NOT a one-off script — it's a first-class background job with progress tracking, resumability, and failure handling.

**Metadata:** Store `{model, context_format_version, chunk_config}` with each Qdrant collection for tracking.

### Product Tier Architecture

> **Decided 2026-04-02.** SaaS-only at launch. See `docs/context/pricing-strategy.md` for full model.

| Tier | Price | Embedding | Features |
|------|-------|-----------|----------|
| **Starter** | $5/mo ($50/yr) | voyage-4-large (text, 1024d) | Text search, MCP (read+write), WebSocket sync, 5 devices, 10GB storage |
| **Pro** | $10/mo ($100/yr) | voyage-4-large + multimodal (future) | Everything in Starter + unlimited devices, 50GB storage, 2x rate limit, Publish (future) |

14-day free trial (card required). 30% launch discount for first 3 months. Team tier post-launch.

Multimodal upgrade (Pro, post-launch) requires re-embedding with voyage-multimodal-3.5, but same 1024d dims so storage footprint unchanged.

## Context Docs

If you need info on Starlette/Jinja2 template issues, see `docs/context/starlette-1.0-templates.md`.

## Life OS
project: engram
goal: income
value: financial-freedom

@/home/open-claw/documents/code-projects/ops-agent/docs/self-updating-docs.md
