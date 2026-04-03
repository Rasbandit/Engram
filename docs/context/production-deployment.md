# Context Doc: Production Deployment (SaaS — Fly.io)

_Last verified: 2026-04-03_

## Status
Working — infrastructure setup TODO (see checklist in `docs/context/elixir-architecture-decisions.md`).

## What This Is
SaaS infrastructure, deploy process, backups, observability, and security hardening checklist.

## SaaS Infrastructure

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

## Deploy Process

```bash
# First deploy
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

## Fly.io Phoenix Specifics

- `fly launch` runs `mix phx.gen.release --docker` and appends IPv6 config
- `release_command = "/app/bin/migrate"` runs Ecto migrations before each deploy
- `dns_cluster` auto-clusters machines via Fly's `.internal` DNS (AAAA records)
- PgBouncer (Fly Postgres default) uses transaction mode — fine for Ecto, no LISTEN/NOTIFY needed
- `RELEASE_COOKIE` must be pinned as a Fly secret (Docker rebuilds randomize it otherwise)
- WebSocket connections handled natively by Fly's proxy (TLS terminated at edge)

## Backups (Decided 2026-04-02)

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

**Qdrant Cloud:** Has its own backup/snapshot system. Free tier includes daily snapshots. Qdrant data is reconstructable from Postgres (re-embed all notes), so Qdrant backups are convenience, not critical.

## Observability (Decided 2026-04-02)

**Stack:** PromEx (auto-instrumentation) + Sentry (error tracking). Both have free tiers.

**PromEx** (`prom_ex` hex package) auto-instruments:
- **Phoenix** — request latency/count by endpoint, WebSocket connection count
- **Ecto** — query duration, pool checkout time
- **Oban** — job duration, queue depth, failure rate, retry count
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

**Future:** Add Grafana Cloud (free tier) for dashboards and alerting when there are paying users.

## Security Hardening (Open — Needs Design)

| Item | Status | Notes |
|------|--------|-------|
| **CORS policy** | TODO | Allow plugin origin (`app://obsidian.md`) + configured domains |
| **CSP headers** | TODO | Restrictive policy for web UI pages |
| **Request body size limit** | TODO | 10MB max (matches `MAX_NOTE_SIZE`). Phoenix default is 8MB |
| **WebSocket origin check** | TODO | Phoenix `check_origin` config |
| **WebSocket message rate limit** | TODO | Hammer check in Channel `handle_in`. ~60 msgs/min per connection |
| **API key revocation** | TODO | Need immediate ETS cache invalidation on revoke |
| **Secret rotation procedure** | TODO | Generate new → set as Fly secret → deploy → old JWT sessions expire (7-day) |
| **TLS** | Done | Fly.io terminates TLS at edge automatically |
| **Quota enforcement** | TODO — Deep dive | Requires dedicated design session. Blocked on Phase 10 (Billing) decisions |

## Data Migration Strategy (Decided 2026-04-02)

**Decision:** Fresh launch. No data migration needed — clean start with the Elixir backend.

## References
- Fly config: `fly.toml`
- Docker Compose (dev/CI): `docker-compose.yml`
- Pricing: `docs/context/pricing-strategy.md`
