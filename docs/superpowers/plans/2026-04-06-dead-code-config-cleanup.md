# Dead Code & Config Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove dead code, fix config issues, and correct documentation mismatches. Low-risk changes that reduce confusion and attack surface.

**Architecture:** All tasks are independent. Mostly deletions, config edits, and doc updates. No business logic changes.

**Tech Stack:** Elixir config, Oban, Req

**Reference:** See `docs/context/code-audit-2026-04.md` for audit findings (C5, C6, C7, H13, H14, H15, H16).

---

### Task 1: Remove phantom `reindex` Oban queue (C6)

**Files:**
- Modify: `config/config.exs:51`

- [ ] **Step 1: Verify no worker uses the reindex queue**

Run: `grep -r "queue: :reindex" lib/`
Expected: No matches.

- [ ] **Step 2: Remove the queue from config**

In `config/config.exs`, change line 51 from:

```elixir
  queues: [embed: 5, reindex: 1, maintenance: 2],
```

to:

```elixir
  queues: [embed: 5, maintenance: 2],
```

- [ ] **Step 3: Run tests**

Run: `mix test`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add config/config.exs
git commit -m "fix: remove phantom reindex Oban queue — no worker uses it"
```

---

### Task 2: Fix Voyage API key log exposure (C7)

**Files:**
- Modify: `lib/engram/embedders/voyage.ex:33-38`
- Test: `test/engram/embedders/voyage_test.exs` (existing)

- [ ] **Step 1: Write the failing test**

Add to `test/engram/embedders/voyage_test.exs`:

```elixir
test "uses Req :auth option instead of raw header" do
  # This is a structural test — we verify the request uses :auth
  # by mocking and inspecting the request options.
  # For now, verify the module compiles and the function signature is correct.
  assert function_exported?(Engram.Embedders.Voyage, :embed_texts, 1)
  assert function_exported?(Engram.Embedders.Voyage, :embed_texts, 2)
end
```

Note: The real verification is code review — Req's `:auth` option is auto-redacted from debug logs while raw headers are not.

- [ ] **Step 2: Change raw header to Req :auth option**

In `lib/engram/embedders/voyage.ex`, change lines 32-39 from:

```elixir
    result =
      Req.post("#{url}/v1/embeddings",
        json: %{input: texts, model: model},
        headers: [{"authorization", "Bearer #{api_key}"}],
        receive_timeout: 30_000,
        retry: :transient,
        max_retries: 3
      )
```

to:

```elixir
    result =
      Req.post("#{url}/v1/embeddings",
        json: %{input: texts, model: model},
        auth: {:bearer, api_key},
        receive_timeout: 30_000,
        retry: :transient,
        max_retries: 3
      )
```

- [ ] **Step 3: Run tests**

Run: `mix test test/engram/embedders/voyage_test.exs -v`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add lib/engram/embedders/voyage.ex
git commit -m "fix: use Req :auth option for Voyage API key — prevents log exposure

Req auto-redacts :auth from debug logs. Raw Authorization headers
could leak API keys when Logger is at debug level."
```

---

### Task 3: Move TestWorker to test/support (H13)

**Files:**
- Move: `lib/engram/workers/test_worker.ex` → `test/support/test_worker.ex`
- Modify: `test/engram/oban_test.exs` (if it references the old path)

- [ ] **Step 1: Verify TestWorker is only referenced in tests**

Run: `grep -r "TestWorker" lib/`
Expected: Only `lib/engram/workers/test_worker.ex` itself.

Run: `grep -r "TestWorker" test/`
Expected: `test/engram/oban_test.exs`

- [ ] **Step 2: Move the file**

```bash
mv lib/engram/workers/test_worker.ex test/support/test_worker.ex
```

- [ ] **Step 3: Run tests**

Run: `mix test test/engram/oban_test.exs -v`
Expected: PASS — test/support/ is compiled for the test env automatically.

- [ ] **Step 4: Commit**

```bash
git add -A lib/engram/workers/test_worker.ex test/support/test_worker.ex
git commit -m "fix: move TestWorker from lib/ to test/support/

Test-only module should not ship in production releases."
```

---

### Task 4: Remove dead ClientLog.changeset/2 (H14)

**Files:**
- Modify: `lib/engram/logs/client_log.ex`

- [ ] **Step 1: Verify changeset is never called**

Run: `grep -r "ClientLog.changeset\|client_log_changeset\|ClientLog\).changeset" lib/ test/`
Expected: Only the definition in `client_log.ex`, no callers.

- [ ] **Step 2: Read the file**

Read `lib/engram/logs/client_log.ex` to see exact code.

- [ ] **Step 3: Remove dead changeset and unused import**

Remove the `import Ecto.Changeset` and the `changeset/2` function. Keep the schema.

- [ ] **Step 4: Run tests**

Run: `mix test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/engram/logs/client_log.ex
git commit -m "fix: remove dead ClientLog.changeset/2 — never called

Logs.insert_logs/2 uses Repo.insert_all with raw maps.
The changeset was defined but never used anywhere."
```

---

### Task 5: Enable production DB SSL (H15)

**Files:**
- Modify: `config/runtime.exs:126-129`

- [ ] **Step 1: Uncomment SSL in prod Repo config**

In `config/runtime.exs`, change the prod Repo config from:

```elixir
  config :engram, Engram.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6
```

to:

```elixir
  config :engram, Engram.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6,
    ssl: System.get_env("DB_SSL", "true") == "true"
```

- [ ] **Step 2: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add config/runtime.exs
git commit -m "fix: enable SSL for production database connections

Defaults to true (Fly.io Postgres requires it). Can be overridden
with DB_SSL=false for local/Docker setups."
```

---

### Task 6: Add VOYAGE_API_KEY validation in prod (H16)

**Files:**
- Modify: `config/runtime.exs:37-47`

- [ ] **Step 1: Add validation when backend is Voyage in prod**

In `config/runtime.exs`, change the embedder config block from:

```elixir
  case System.get_env("EMBED_BACKEND", "voyage") do
    "ollama" ->
      config :engram, :embedder, Engram.Embedders.Ollama

    _ ->
      config :engram, :embedder, Engram.Embedders.Voyage

      if api_key = System.get_env("VOYAGE_API_KEY") do
        config :engram, :voyage_api_key, api_key
      end
  end
```

to:

```elixir
  case System.get_env("EMBED_BACKEND", "voyage") do
    "ollama" ->
      config :engram, :embedder, Engram.Embedders.Ollama

    _ ->
      config :engram, :embedder, Engram.Embedders.Voyage

      api_key = System.get_env("VOYAGE_API_KEY")

      if api_key do
        config :engram, :voyage_api_key, api_key
      else
        if config_env() == :prod do
          raise "VOYAGE_API_KEY is required when EMBED_BACKEND=voyage in production"
        end
      end
  end
```

- [ ] **Step 2: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add config/runtime.exs
git commit -m "fix: raise on missing VOYAGE_API_KEY in production

Previously the app started silently without an API key, causing
opaque runtime errors on first embedding call."
```

---

### Task 7: Update CLAUDE.md — fix worker docs (C5)

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update the Oban Workers row in the Target Components table**

In `CLAUDE.md`, change the Oban Workers row from:

```markdown
| Oban Workers | `lib/engram/workers/` | EmbedNote, ReindexAll, PurgeSoftDeletes, RetryDiscarded, OrphanChunkScan |
```

to:

```markdown
| Oban Workers | `lib/engram/workers/` | EmbedNote, ReconcileEmbeddings |
```

- [ ] **Step 2: Fix trial days reference**

Search for "14-day free trial" and change to "7-day free trial" (matching `@trial_days 7` in `billing.ex`), OR change `@trial_days` to 14. Check with product owner. For now, update the doc to match the code:

Change:
```markdown
14-day free trial (card required).
```
to:
```markdown
7-day free trial (card required).
```

- [ ] **Step 3: Remove non-existent Engram.Auth from architecture table**

In the Target Components table, remove the Auth row that references `lib/engram/auth.ex` (file doesn't exist). The auth logic is split across `lib/engram/auth/` submodules and `lib/engram/accounts.ex`.

Change:
```markdown
| Auth | `lib/engram/auth.ex` | API keys, JWT (Joken), RLS context, Argon2 |
```
to:
```markdown
| Auth | `lib/engram/auth/`, `lib/engram/accounts.ex` | Clerk JWT, API keys, legacy JWT (Joken), RLS context |
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: fix CLAUDE.md — correct worker names, trial days, auth module path

- ReindexAll → ReconcileEmbeddings (actual module name)
- Remove PurgeSoftDeletes, RetryDiscarded, OrphanChunkScan (not implemented)
- 14-day → 7-day trial (matches @trial_days in billing.ex)
- Auth path: lib/engram/auth.ex → lib/engram/auth/ + accounts.ex"
```
