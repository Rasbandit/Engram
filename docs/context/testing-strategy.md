# Context Doc: Testing Strategy

_Last verified: 2026-04-03_

## Status
Working — ExUnit tests being written as modules are built. Integration and E2E tests are language-agnostic and serve as the migration acceptance gate.

## What This Is
Testing philosophy, test layers, tooling, and CI pipeline for the Engram Elixir/Phoenix backend.

## Philosophy

**Tests are the spec. If a test fails, fix the app — not the test.**

## Test Layers

| Layer | Location | Command | What it tests | Infra needed |
|-------|----------|---------|---------------|--------------|
| **Unit tests** | `test/` | `mix test` | Pure logic: path sanitization, note helpers, auth, RLS context | None (Ecto.Sandbox) |
| **Integration tests** | `test_plan.sh` | `bash test_plan.sh` | Full API contract (HTTP-based, language-agnostic) | Docker Compose stack |
| **E2E tests** | `e2e/tests/` | `python3 -m pytest e2e/tests/ -v` | Real Obsidian sync: push/pull, Channels, conflicts, multi-user | CI stack + Obsidian |
| **E2E helper unit tests** | `e2e/unit_tests/` | `python3 -m pytest e2e/unit_tests/ -v` | SQL injection prevention in cleanup helpers | None |

## Elixir Testing Stack

| Tool | Purpose |
|------|---------|
| **ExUnit** | Test framework |
| **Ecto.Adapters.SQL.Sandbox** | Per-test DB transactions (auto-rollback) |
| **ExMachina** | Test data factories |
| **Mox** | Behaviour-based mocks (embedder, Qdrant client) |
| **Bypass** | HTTP mock server (for Voyage AI, Qdrant API) |

Key advantage: `async: true` runs tests in parallel with per-test DB transactions. No cleanup needed.

## RLS Testing (Critical)

Every test must verify tenant isolation:
- Query as User A with User B's tenant context → must return zero rows
- Insert as User A, attempt read as User B → must fail
- `FORCE ROW LEVEL SECURITY` means even the table owner can't bypass policies

See `docs/context/database-schema-rls.md` for the RLS spike test example.

## CI Pipeline

All tests run in GitHub Actions (`.github/workflows/ci.yml`):

1. **Unit tests** — `mix test` + `python3 -m pytest e2e/unit_tests/ -v` (E2E helpers)
2. **Integration tests** — starts CI stack, runs `test_plan.sh`
3. **E2E tests** — starts CI stack + headless Obsidian, runs full sync scenarios (main branch only)

**Code quality checks:** `mix format --check-formatted` and `mix credo`. Dialyzer optional (slow, add later).

## References
- ExUnit tests: `test/`
- Integration tests: `test_plan.sh`
- E2E tests: `e2e/tests/`
- CI config: `.github/workflows/ci.yml`
