# Context Doc: Elixir Codebase Audit (April 2026)

_Last verified: 2026-04-06_

## Status
Active — findings pending resolution

## What This Is
Comprehensive audit of ~5,900 LOC across ~70 Elixir files. Covers security, correctness, performance, dead code, DRY violations, and architecture gaps. Run by 6 parallel deep-dive agents reading every line.

## Environment
Elixir 1.17+ / Phoenix / Ecto / Oban / Req / ExAws — deployed on Fly.io (SaaS target).

## Findings Summary

| Severity | Count | Theme |
|----------|-------|-------|
| CRITICAL | 7 | Security controls exist but aren't wired up; data corruption; crash risks |
| HIGH | 18 | RLS gaps, WebSocket origin bypass, N+1 queries, crash bugs in channels/MCP |
| MEDIUM | 30 | DRY violations, missing validation, race conditions, inconsistent patterns |
| LOW | 25+ | Tech debt, missing docs, test gaps, minor config issues |

---

## CRITICAL (7)

### C1. Subscription enforcement plug never wired into router
- **File:** `lib/engram_web/router.ex`
- `RequireActiveSubscription` exists and has tests but no route uses it. All authenticated API endpoints accessible without subscription.
- **Fix:** Add to authenticated API pipeline after `Plugs.Auth`.

### C2. Rate limiting configured but never enforced
- **Files:** `config/config.exs:36-44`, entire codebase
- Hammer is configured but `Hammer.check_rate/3` never called anywhere.
- **Fix:** Add rate-limiting to `/users/login`, `/users/register`, `/notes`, `/search`.

### C3. Path sanitizer corrupts legitimate filenames
- **File:** `lib/engram/notes/path_sanitizer.ex:41`
- `String.replace("..", "")` runs before `reject_traversal/1`. `"v2..3-notes.md"` becomes `"v23-notes.md"`. The `reject_traversal/1` guard already handles standalone `".."` segments.
- **Fix:** Remove line 41 entirely.

### C4. `String.to_existing_atom(tier)` crash risk in billing
- **File:** `lib/engram/billing.ex:21`
- Unexpected tier string raises `ArgumentError`, crashing the request.
- **Fix:** Use hardcoded map `%{"trial" => :trial, "starter" => :starter, "pro" => :pro}`.

### C5. Three documented Oban workers don't exist
- **Files:** CLAUDE.md vs `lib/engram/workers/`
- `PurgeSoftDeletes`, `RetryDiscarded`, `OrphanChunkScan` documented but never implemented.
- Also: `ReindexAll` in docs is actually `ReconcileEmbeddings` in code.
- **Fix:** Implement or remove from docs.

### C6. `reindex` Oban queue configured but no worker uses it
- **File:** `config/config.exs:50`
- `queues: [embed: 5, reindex: 1, maintenance: 2]` — `reindex: 1` wastes a DB polling slot.
- **Fix:** Remove `reindex: 1`.

### C7. API key potentially visible in Req debug logs
- **File:** `lib/engram/embedders/voyage.ex:35`
- Bearer token passed as raw header instead of Req's `:auth` option (auto-redacted from logs).
- **Fix:** Use `auth: {:bearer, api_key}`.

---

## HIGH (18)

### H1. RLS missing on `client_logs` and `subscriptions` tables
- **Files:** Migrations `20260403090821`, `20260405075213`
- Both have `user_id` but no RLS policies. `Engram.Logs` uses `skip_tenant_check: true`.

### H2. WebSocket `check_origin: false` in production
- **Files:** `lib/engram_web/endpoint.ex:6`, `config/config.exs:27`
- Never overridden for prod.
- **Fix:** Override in `runtime.exs`: `["https://#{host}", "app://obsidian.md"]`.

### H3. `CacheRawBody` silently drops chunks on large payloads
- **File:** `lib/engram_web/plugs/cache_raw_body.ex:13-14`
- `{:more, ...}` returns only first chunk. Stripe webhook verification could verify truncated body.

### H4. Legacy JWT has no issuer/audience validation
- **File:** `lib/engram/token.ex`
- Only validates `exp`. Any JWT with valid `user_id` and matching secret accepted.
- **Fix:** Add `iss: "engram", aud: "engram"`.

### H5. CORS allows all origins with `*`
- **File:** `lib/engram_web/plugs/cors.ex:24`

### H6. `rename_folder` N+1 UPDATE queries
- **File:** `lib/engram/notes.ex:395-400`
- Each note gets individual `Repo.update_all`. 500 notes = 500 SQL statements.
- **Fix:** Single bulk UPDATE.

### H7. Unbounded queries in multiple locations
- **Files:** `notes.ex:193`, `attachments.ex`, `sync_controller.ex`, `sync_channel.ex`
- No `LIMIT` on changes/manifest queries. OOM risk.

### H8. `suggest_folder` MCP handler crashes at runtime
- **File:** `lib/engram/mcp/handlers.ex:140-148`
- Concatenates header strings with tuples then maps expecting tuples only. `FunctionClauseError`.

### H9. `SyncChannel.delete_note` pattern-matches `:ok` on wrong return type
- **File:** `lib/engram_web/channels/sync_channel.ex:82`
- `Notes.delete_note/2` returns `{count, nil}`, not `:ok`. Crashes with `MatchError`.

### H10. WebSocket channel bypasses HTTP note size limit
- **File:** `lib/engram_web/channels/sync_channel.ex:51`
- Controller has `@max_note_bytes`. Channel has no size check.

### H11. Fat controllers with raw Ecto queries
- **Files:** `embed_status_controller.ex:12-31`, `sync_controller.ex:13-33`

### H12. No log ingestion limit
- **File:** `lib/engram_web/controllers/logs_controller.ex:6-9`
- Accepts unbounded list of logs. DoS vector.

### H13. `TestWorker` ships in production
- **File:** `lib/engram/workers/test_worker.ex`
- Test-only module in `lib/`. Move to `test/support/`.

### H14. `ClientLog.changeset/2` is dead code
- **File:** `lib/engram/logs/client_log.ex:19-32`
- Never called. `Logs.insert_logs/2` uses raw `Repo.insert_all`.

### H15. Production DB SSL commented out
- **File:** `config/runtime.exs:139`

### H16. No `VOYAGE_API_KEY` validation in prod
- **File:** `config/runtime.exs:53-57`

### H17. `price_id_for/1` returns `nil` silently
- **File:** `lib/engram/billing.ex:173-174`

### H18. `tier_from_price_id/1` defaults to `"starter"` on unknown price
- **File:** `lib/engram/billing.ex:180`

---

## MEDIUM (30)

| # | File | Issue |
|---|------|-------|
| M1 | `notes.ex:226-241` | `list_tags` loads all tag arrays into Elixir instead of SQL `unnest()` |
| M2 | `notes.ex:271-292` | `list_tags_with_counts` groups in Elixir not SQL |
| M3 | `notes/helpers.ex:82-106` | YAML tag parser doesn't handle multi-line `tags:` lists |
| M4 | `parsers/markdown.ex:228-233` | `extract_folder/1` duplicated from `Helpers` |
| M5 | `parsers/markdown.ex:47` | `strip_frontmatter` mixes byte offsets with grapheme `String.slice` |
| M6 | `indexing.ex:52` | `delete_note_index/1` — no production caller (dead code) |
| M7 | `search.ex:41` | No query length validation |
| M8 | `note.ex` | Missing `@type t()` definition |
| M9 | `auth/clerk_token.ex:29-31` | `rescue _ ->` swallows all exceptions including JWKS outages |
| M10 | `auth/clerk_token.ex:19-22` | Issuer validated with `==` not `secure_compare`; `nil` config passes |
| M11 | `accounts.ex:48-65` | `find_or_create_by_clerk_id` TOCTOU race condition |
| M12 | `billing.ex:120` | `String.to_integer` on untrusted Stripe webhook data |
| M13 | `billing.ex:109-138` | No idempotency on duplicate webhooks |
| M14 | `repo.ex:21` | SQL interpolation in `SET LOCAL` — safe due to integer guard but fragile |
| M15 | `webhook_controller.ex:28` | Error responses leak implementation details |
| M16 | `webhook_controller.ex:14` | `Jason.decode!` can crash on invalid JSON |
| M17 | `qdrant.ex` | Same 3-clause error handling repeated 6 times |
| M18 | `qdrant.ex:86` | No payload size guard on `upsert_points` |
| M19 | `voyage.ex:30` | `raise` on missing config crashes Oban workers |
| M20 | `voyage.ex:40-51` | No 429 rate limit handling |
| M21 | `ollama.ex:26` | Uses `System.get_env` while rest uses `Application.get_env` |
| M22 | `jina.ex:20` | `raise` on missing config in search path |
| M23 | `jina.ex:33-37` | Jina API key not sent in auth header |
| M24 | `storage/database.ex:119` | `String.to_integer` crash on malformed key |
| M25 | `storage/database.ex:23-50` | SELECT-then-INSERT race condition |
| M26 | `attachments.ex:110-115` | `delete_attachment` ignores `Repo.with_tenant` result |
| M27 | `attachments/attachment.ex:5` | `@max_attachment_bytes` hardcoded — should vary by tier |
| M28 | `application.ex:25` | `:one_for_one` where `:rest_for_one` fits dependency chain |
| M29 | `sync_channel.ex:54-72` | Version conflict not handled — crashes channel |
| M30 | `folders_controller.ex:25`, `auth_controller.ex:39` | Missing param fallbacks → 500 |

---

## LOW (25+)

- `@trial_days 7` vs CLAUDE.md says 14-day trial
- `format_errors` delegated identically in 4 controllers
- No `Content-Security-Policy` header
- SPA routes missing security headers pipeline
- `Engram.Auth` module documented but doesn't exist
- `Accounts.verify_jwt/1` is a pass-through
- Missing `@moduledoc` on `Chunk`
- Deprecated `get_flash` imports in `engram_web.ex`
- No tests for: Ollama embedder, CORS plug, CacheRawBody plug, MCP handlers (unit), FoldersController
- `detect_mime/1` reimplements what `mime` hex package does
- Storage limit hardcoded at 1GB but tiers say 10/50GB
- Telemetry metrics defined but no reporter configured
- Double-encoded path traversal not mitigated (minor edge case)
- `_title` unused param in `split_into_sections/2`
- `_sub_idx` temp key pattern in parser
- No `@type t()` on `Chunk`
- `Engram` root module is stub
- `EngramWeb.Gettext` likely unused
- Dev config has hardcoded `secret_key_base` (fine for dev)
- `ReconcileEmbeddings` doesn't log zero-stale case
- `EmbedNote.new_debounced/2` doesn't validate `note_id` type
- `require Logger` inside function bodies in 3 files

---

## Architecture Gaps

```
Documented but missing / broken:
- 3 Oban workers (purge, retry, orphan scan)
- Engram.Auth context module
- Subscription enforcement on routes
- Rate limiting enforcement
- Device count enforcement via Presence
- RLS on client_logs + subscriptions
- ReindexAll (actually ReconcileEmbeddings)
```

## Key Patterns Observed

1. **Security controls exist but aren't wired up** — subscription plug, rate limiter, RLS policies are implemented but never activated. Creates false confidence.
2. **"Two front doors" problem** — WebSocket channel duplicates controller validations and gets them wrong. Validation must live in shared context layer.
3. **Inconsistent error patterns** — `:ok` vs `{:ok, _}` vs `{count, nil}` vs `{:error, atom}` vs `{:error, changeset}` vs `{:error, atom, data}`. Makes error handling fragile.

## References
- Audit performed: 2026-04-06
- Branch: `fix/dead-code-cleanup`
- Related: `docs/context/database-schema-rls.md`, `docs/context/testing-strategy.md`
