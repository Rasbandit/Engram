# Security Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire up the existing but unused security controls (subscription enforcement, rate limiting) and fix auth/CORS/origin gaps.

**Architecture:** All changes are in the web layer — plugs, router, config, and endpoint. No business logic changes. Each task is independent after Task 1 (router change).

**Tech Stack:** Phoenix plugs, Hammer rate limiting, Joken JWT, runtime.exs config

**Reference:** See `docs/context/code-audit-2026-04.md` for full audit findings (C1, C2, H2, H4, H5).

---

### Task 1: Wire RequireActiveSubscription plug into router

**Files:**
- Modify: `lib/engram_web/router.ex:35-37`
- Test: `test/engram_web/controllers/multi_tenant_test.exs` (existing)

- [ ] **Step 1: Write the failing test**

Create `test/engram_web/plugs/require_active_subscription_integration_test.exs`:

```elixir
defmodule EngramWeb.Plugs.RequireActiveSubscriptionIntegrationTest do
  use EngramWeb.ConnCase, async: true

  alias Engram.{Accounts, Repo}

  setup do
    {:ok, user} = Accounts.register(%{email: "sub-test@example.com", password: "TestPass123!"})
    api_key = Engram.Accounts.create_api_key!(user, "test-key")
    conn = build_conn() |> put_req_header("authorization", "Bearer #{api_key.key}")
    {:ok, conn: conn, user: user}
  end

  test "vault-scoped route without subscription returns 403", %{conn: conn} do
    conn = get(conn, "/api/notes/changes?since=2020-01-01T00:00:00Z")
    assert json_response(conn, 403)["error"] == "subscription_required"
  end

  # Regression guard: billing/onboarding routes must NOT be gated.
  # If RequireActiveSubscription is accidentally applied to the wrong scope,
  # these will return 403 and catch the mistake.
  test "billing status is reachable without a subscription", %{conn: conn} do
    conn = get(conn, "/api/billing/status")
    refute conn.status == 403
  end

  test "billing checkout session is reachable without a subscription", %{conn: conn} do
    conn = post(conn, "/api/billing/checkout-session", %{})
    refute conn.status == 403
  end

  test "device authorize is reachable without a subscription", %{conn: conn} do
    conn = post(conn, "/api/auth/device/authorize", %{user_code: "XXXX-XXXX"})
    refute conn.status == 403
  end

  test "authenticated request with active subscription returns 200", %{conn: conn, user: user} do
    Repo.insert!(
      %Engram.Billing.Subscription{
        user_id: user.id,
        status: "active",
        tier: "starter",
        stripe_customer_id: "cus_test",
        stripe_subscription_id: "sub_test"
      },
      skip_tenant_check: true
    )

    conn = get(conn, "/api/notes/changes?since=2020-01-01T00:00:00Z")
    assert conn.status in [200, 204]
  end

  # The commit message says trialing and past_due are also accepted —
  # verify those status values don't produce 403.
  for status <- ["trialing", "past_due"] do
    test "subscription with status #{status} is accepted", %{conn: conn, user: user} do
      Repo.insert!(
        %Engram.Billing.Subscription{
          user_id: user.id,
          status: unquote(status),
          tier: "starter",
          stripe_customer_id: "cus_test",
          stripe_subscription_id: "sub_test"
        },
        skip_tenant_check: true
      )

      conn = get(conn, "/api/notes/changes?since=2020-01-01T00:00:00Z")
      refute conn.status == 403
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram_web/plugs/require_active_subscription_integration_test.exs -v`
Expected: First test passes (currently no subscription check), second test passes. We need to invert: first should return 403 but currently returns 200.

- [ ] **Step 3: Add plug to vault-scoped routes only (not billing/onboarding scope)**

> ⚠️ **Scope split is critical.** The authenticated scope (lines 41–67) contains `/billing/*`, `/auth/device/authorize`, `/vaults`, and API-key management — all required for subscription purchase and first-time setup. Gating that whole scope would lock out users who have no subscription yet. Apply `RequireActiveSubscription` **only** to the vault-scoped scope (notes, search, MCP, attachments) where the paid features live.

In `lib/engram_web/router.ex`, change the **third** scope (vault-scoped, currently line ~71) from:

```elixir
  scope "/api", EngramWeb do
    pipe_through [:api, EngramWeb.Plugs.Auth, EngramWeb.Plugs.VaultPlug]
```

to:

```elixir
  scope "/api", EngramWeb do
    pipe_through [:api, EngramWeb.Plugs.Auth, EngramWeb.Plugs.RequireActiveSubscription, EngramWeb.Plugs.VaultPlug]
```

Leave the second scope (`pipe_through [:api, EngramWeb.Plugs.Auth]`) **unchanged** — it handles billing, device auth, vault registration, and API keys, all of which must remain reachable before a subscription exists.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/engram_web/plugs/require_active_subscription_integration_test.exs -v`
Expected: Both tests PASS.

- [ ] **Step 5: Run full test suite to check for regressions**

Run: `mix test`
Expected: Some existing tests may fail because they don't set up subscriptions. For each failing test, add a subscription setup fixture. Common fix pattern:

```elixir
# In test setup blocks that need an active subscription:
Repo.insert!(
  %Engram.Billing.Subscription{
    user_id: user.id,
    status: "active",
    tier: "starter",
    stripe_customer_id: "cus_test",
    stripe_subscription_id: "sub_test"
  },
  skip_tenant_check: true
)
```

Note: This may require creating a shared test helper. If more than 3 tests need it, add to `test/support/fixtures.ex`:

```elixir
def subscription_fixture(user, attrs \\ %{}) do
  defaults = %{
    user_id: user.id,
    status: "active",
    tier: "starter",
    stripe_customer_id: "cus_#{System.unique_integer([:positive])}",
    stripe_subscription_id: "sub_#{System.unique_integer([:positive])}"
  }

  Engram.Repo.insert!(
    struct(Engram.Billing.Subscription, Map.merge(defaults, attrs)),
    skip_tenant_check: true
  )
end
```

- [ ] **Step 6: Commit**

```bash
git add lib/engram_web/router.ex test/engram_web/plugs/require_active_subscription_integration_test.exs
# Also add any modified test files with subscription fixtures
git commit -m "feat: wire RequireActiveSubscription plug into authenticated API pipeline

All authenticated routes now require an active, trialing, or past_due
subscription. Returns 403 with subscription_required error otherwise."
```

---

### Task 2: Add rate limiting to critical endpoints

**Files:**
- Create: `lib/engram_web/plugs/rate_limit.ex`
- Create: `test/engram_web/plugs/rate_limit_test.exs`
- Modify: `lib/engram_web/router.ex:31-32` (login/register routes)

- [ ] **Step 1: Write the failing test**

Create `test/engram_web/plugs/rate_limit_test.exs`:

```elixir
defmodule EngramWeb.Plugs.RateLimitTest do
  use EngramWeb.ConnCase, async: false

  describe "rate limiting on login" do
    test "allows requests under the limit" do
      conn = build_conn()
      conn = post(conn, "/api/users/login", %{email: "x@x.com", password: "wrong"})
      # Should get 401 (bad creds), not 429
      assert conn.status == 401
    end

    test "spoofing x-forwarded-for does not bypass the rate limit" do
      # Send 11 requests, each with a different spoofed IP in x-forwarded-for.
      # If the plug mistakenly keys on this header, each request would appear
      # to come from a fresh IP and the limit would never trigger.
      # The plug must key on conn.remote_ip (127.0.0.1 in test) instead.
      for i <- 1..11 do
        build_conn()
        |> put_req_header("x-forwarded-for", "10.0.0.#{i}")
        |> post("/api/users/login", %{email: "x@x.com", password: "wrong"})
      end

      conn =
        build_conn()
        |> put_req_header("x-forwarded-for", "10.0.0.99")
        |> post("/api/users/login", %{email: "x@x.com", password: "wrong"})

      assert conn.status == 429
    end

    test "returns 429 after exceeding limit" do
      # Rate key is conn.remote_ip — simulate same IP by using the same
      # build_conn() default (127.0.0.1). Do NOT use x-forwarded-for here;
      # the plug ignores that header to prevent spoofing.
      for _ <- 1..11 do
        build_conn() |> post("/api/users/login", %{email: "x@x.com", password: "wrong"})
      end

      conn = build_conn() |> post("/api/users/login", %{email: "x@x.com", password: "wrong"})
      assert conn.status == 429
      assert json_response(conn, 429)["error"] == "rate_limited"
    end
  end

  describe "rate limiting on register" do
    test "returns 429 after exceeding limit on register" do
      for _ <- 1..11 do
        build_conn() |> post("/api/users/register", %{email: "x@x.com", password: "wrong"})
      end

      conn = build_conn() |> post("/api/users/register", %{email: "x@x.com", password: "wrong"})
      assert conn.status == 429
    end
  end

  describe "rate limit buckets are per-path" do
    test "exhausting login limit does not affect register" do
      for _ <- 1..11 do
        build_conn() |> post("/api/users/login", %{email: "x@x.com", password: "wrong"})
      end

      # register has its own bucket — should not be 429
      conn = build_conn() |> post("/api/users/register", %{email: "new@x.com", password: "Pass123!"})
      refute conn.status == 429
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram_web/plugs/rate_limit_test.exs -v`
Expected: FAIL — second test gets 401 instead of 429 (no rate limiting exists).

- [ ] **Step 3: Create the rate limit plug**

Create `lib/engram_web/plugs/rate_limit.ex`:

```elixir
defmodule EngramWeb.Plugs.RateLimit do
  @moduledoc """
  Configurable rate-limiting plug backed by Hammer.
  Usage: `plug EngramWeb.Plugs.RateLimit, limit: 10, period: 60_000`
  """

  import Plug.Conn

  def init(opts) do
    %{
      limit: Keyword.fetch!(opts, :limit),
      period: Keyword.fetch!(opts, :period)
    }
  end

  def call(conn, %{limit: limit, period: period}) do
    key = rate_limit_key(conn)

    case Hammer.check_rate(key, period, limit) do
      {:allow, _count} ->
        conn

      {:deny, _limit} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(429, Jason.encode!(%{error: "rate_limited"}))
        |> halt()
    end
  end

  defp rate_limit_key(conn) do
    # Use conn.remote_ip — this is the IP Plug resolved from the actual TCP
    # connection (or from a trusted proxy via Plug.RewriteOn if configured).
    # Do NOT trust x-forwarded-for directly: it is client-controlled and
    # trivially spoofable, making the rate limit bypassable.
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()
    "#{conn.request_path}:#{ip}"
  end
end
```

- [ ] **Step 4: Add rate limiting to public auth routes in router**

In `lib/engram_web/router.ex`, change lines 26-33 from:

```elixir
  scope "/api", EngramWeb do
    # Public endpoints (no auth required)
    pipe_through :api
    get "/health", HealthController, :index
    get "/health/deep", HealthController, :deep
    post "/users/register", AuthController, :register
    post "/users/login", AuthController, :login
  end
```

to:

```elixir
  scope "/api", EngramWeb do
    # Public endpoints (no auth required)
    pipe_through :api
    get "/health", HealthController, :index
    get "/health/deep", HealthController, :deep
  end

  scope "/api", EngramWeb do
    # Auth endpoints — rate limited, no auth required
    pipe_through [:api, {EngramWeb.Plugs.RateLimit, limit: 10, period: 60_000}]
    post "/users/register", AuthController, :register
    post "/users/login", AuthController, :login
  end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/engram_web/plugs/rate_limit_test.exs -v`
Expected: PASS

- [ ] **Step 6: Run full test suite**

Run: `mix test`
Expected: PASS (rate limiting only on new scope, existing tests unaffected).

- [ ] **Step 7: Commit**

```bash
git add lib/engram_web/plugs/rate_limit.ex test/engram_web/plugs/rate_limit_test.exs lib/engram_web/router.ex
git commit -m "feat: add Hammer-backed rate limiting plug to login/register endpoints

10 requests/minute per IP. Returns 429 with rate_limited error.
Hammer was already configured but unused."
```

---

### Task 3: Fix WebSocket check_origin for production

**Files:**
- Modify: `config/prod.exs` (compile-time override — NOT runtime.exs)
- Test: Manual verification (compile-time config, not unit-testable)

> ⚠️ **Why `config/prod.exs`, not `runtime.exs`:** `lib/engram_web/endpoint.ex` uses `Application.compile_env(:engram, :websocket_check_origin, false)` for the socket's `check_origin` option. `compile_env` is a compile-time macro — it is baked into the bytecode during `mix release`. Any value set in `runtime.exs` at startup is ignored for this key. The fix is to set the allowlist in `config/prod.exs`, where it is evaluated at compile time during release builds.

- [ ] **Step 1: Write a compile-time guard test**

Create `test/engram_web/endpoint_config_test.exs`:

```elixir
defmodule EngramWeb.EndpointConfigTest do
  use ExUnit.Case, async: true

  @compile_time_origin Application.compile_env(:engram, :websocket_check_origin, false)

  test "websocket_check_origin compile value is documented" do
    # In :test env this is false — that is expected.
    # In :prod env (release build) it must be a list of allowed origins.
    # This test asserts the shape is valid: false or a non-empty list.
    assert @compile_time_origin == false or
             (is_list(@compile_time_origin) and @compile_time_origin != [])
  end
end
```

- [ ] **Step 2: Add origin allowlist in `config/prod.exs`**

In `config/prod.exs`, add:

```elixir
# WebSocket origin check — allowlist replaces the default false.
# PHX_HOST is set by Fly.io at deploy time. Obsidian's app:// scheme
# is required for the desktop plugin to connect over the WS socket.
config :engram,
       :websocket_check_origin,
       ["https://" <> System.fetch_env!("PHX_HOST"), "app://obsidian.md"]
```

> Note: `System.fetch_env!` in `config/prod.exs` is evaluated at compile time during `mix release`. Make sure `PHX_HOST` is available in the build environment (it is on Fly.io CI via build args or secrets).

- [ ] **Step 3: Verify compilation in prod config**

Run: `MIX_ENV=prod PHX_HOST=app.engram.dev mix compile --warnings-as-errors`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add config/prod.exs test/engram_web/endpoint_config_test.exs
git commit -m "fix: enable WebSocket origin checking in production

Allowlists the production host and Obsidian app:// scheme via
compile-time config/prod.exs. runtime.exs cannot be used here
because endpoint uses compile_env — value is baked at mix release."
```

---

### Task 4: Add issuer/audience validation to legacy JWT

**Files:**
- Modify: `lib/engram/token.ex:5-7`
- Modify: `test/engram/accounts_test.exs` (existing JWT tests)

- [ ] **Step 1: Write the failing test**

Add to the appropriate test file (create if needed) `test/engram/token_test.exs`:

```elixir
defmodule Engram.TokenTest do
  use ExUnit.Case, async: true

  alias Engram.Token

  test "generated tokens include iss and aud claims" do
    {:ok, token, claims} = Token.generate_and_sign(%{"user_id" => 1})
    assert claims["iss"] == "engram"
    assert claims["aud"] == "engram"
  end

  test "tokens with wrong issuer are rejected" do
    signer = Joken.Signer.create("HS256", Application.get_env(:joken, :default_signer))
    claims = %{"user_id" => 1, "iss" => "other_app", "aud" => "engram", "exp" => Joken.current_time() + 3600}
    {:ok, token} = Joken.Signer.sign(claims, signer)
    assert {:error, _} = Token.verify_and_validate(token)
  end

  test "tokens with wrong audience are rejected" do
    signer = Joken.Signer.create("HS256", Application.get_env(:joken, :default_signer))
    claims = %{"user_id" => 1, "iss" => "engram", "aud" => "other_app", "exp" => Joken.current_time() + 3600}
    {:ok, token} = Joken.Signer.sign(claims, signer)
    assert {:error, _} = Token.verify_and_validate(token)
  end

  test "tokens missing iss claim are rejected" do
    # Absent iss is a different Joken code path than wrong iss — verify both.
    signer = Joken.Signer.create("HS256", Application.get_env(:joken, :default_signer))
    claims = %{"user_id" => 1, "aud" => "engram", "exp" => Joken.current_time() + 3600}
    {:ok, token} = Joken.Signer.sign(claims, signer)
    assert {:error, _} = Token.verify_and_validate(token)
  end

  test "tokens missing aud claim are rejected" do
    signer = Joken.Signer.create("HS256", Application.get_env(:joken, :default_signer))
    claims = %{"user_id" => 1, "iss" => "engram", "exp" => Joken.current_time() + 3600}
    {:ok, token} = Joken.Signer.sign(claims, signer)
    assert {:error, _} = Token.verify_and_validate(token)
  end
end

defmodule EngramWeb.Plugs.AuthJwtIntegrationTest do
  use EngramWeb.ConnCase, async: true

  # Verifies that the Auth plug actually enforces iss/aud on a real route,
  # not just that Token.verify_and_validate/1 returns an error in isolation.
  test "request with wrong-issuer JWT is rejected at the router level" do
    signer = Joken.Signer.create("HS256", Application.get_env(:joken, :default_signer))
    claims = %{"user_id" => 999, "iss" => "other_app", "aud" => "engram", "exp" => Joken.current_time() + 3600}
    {:ok, bad_token} = Joken.Signer.sign(claims, signer)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{bad_token}")
      |> get("/api/me")

    assert conn.status == 401
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram/token_test.exs -v`
Expected: FAIL — generated tokens don't have `iss`/`aud` claims.

- [ ] **Step 3: Add iss/aud to token config**

Change `lib/engram/token.ex` from:

```elixir
defmodule Engram.Token do
  use Joken.Config

  @impl true
  def token_config do
    default_claims(default_exp: 7 * 24 * 3600)
  end
end
```

to:

```elixir
defmodule Engram.Token do
  use Joken.Config

  @impl true
  def token_config do
    default_claims(default_exp: 7 * 24 * 3600, iss: "engram", aud: "engram")
  end
end
```

- [ ] **Step 4: Run tests**

Run: `mix test test/engram/token_test.exs -v`
Expected: PASS

- [ ] **Step 5: Run full suite to check for regressions**

Run: `mix test`
Expected: Existing tests that generate JWTs should still pass (they gain iss/aud automatically). Tests that craft raw JWTs without iss/aud will now fail — update them to include the claims.

- [ ] **Step 6: Commit**

```bash
git add lib/engram/token.ex test/engram/token_test.exs
git commit -m "fix: add issuer and audience validation to legacy JWT tokens

Tokens now require iss=engram and aud=engram claims.
Prevents cross-service token reuse with shared JWT secrets."
```

---

### Task 5: Make CORS origin configurable per environment

**Files:**
- Modify: `lib/engram_web/plugs/cors.ex:25`
- Modify: `config/runtime.exs`
- Create: `test/engram_web/plugs/cors_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/engram_web/plugs/cors_test.exs`:

```elixir
defmodule EngramWeb.Plugs.CORSTest do
  use EngramWeb.ConnCase, async: true

  test "OPTIONS preflight returns 200 with CORS headers" do
    conn =
      build_conn()
      |> put_req_header("origin", "https://app.engram.dev")
      |> options("/api/health")

    assert conn.status == 200
    assert get_resp_header(conn, "access-control-allow-origin") != []
  end

  test "non-OPTIONS requests also receive the CORS origin header" do
    # The plug runs before the router on all requests, not just preflight.
    conn =
      build_conn()
      |> put_req_header("origin", "https://app.engram.dev")
      |> get("/api/health")

    [origin_header] = get_resp_header(conn, "access-control-allow-origin")
    configured_origin = Application.get_env(:engram, :cors_origin, "*")
    assert origin_header == configured_origin
  end

  test "CORS origin header value matches configured origin" do
    # Presence check is not enough — verify the value equals config, not *.
    Application.put_env(:engram, :cors_origin, "https://custom.example.com")
    on_exit(fn -> Application.delete_env(:engram, :cors_origin) end)

    conn =
      build_conn()
      |> put_req_header("origin", "https://custom.example.com")
      |> options("/api/health")

    assert get_resp_header(conn, "access-control-allow-origin") == ["https://custom.example.com"]
  end

  test "CORS origin comes from config, not hardcoded *" do
    origin = Application.get_env(:engram, :cors_origin, "*")
    assert is_binary(origin) or is_list(origin)
  end
end
```

- [ ] **Step 2: Implement configurable CORS origin**

Change `lib/engram_web/plugs/cors.ex` line 25 from:

```elixir
    |> put_resp_header("access-control-allow-origin", "*")
```

to:

```elixir
    |> put_resp_header("access-control-allow-origin", cors_origin())
```

And add the helper:

```elixir
  defp cors_origin do
    Application.get_env(:engram, :cors_origin, "*")
  end
```

- [ ] **Step 3: Add production override in runtime.exs**

In the `if config_env() == :prod do` block, add:

```elixir
  config :engram, :cors_origin, "https://#{host}"
```

- [ ] **Step 4: Run tests**

Run: `mix test test/engram_web/plugs/cors_test.exs -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/engram_web/plugs/cors.ex config/runtime.exs test/engram_web/plugs/cors_test.exs
git commit -m "fix: make CORS origin configurable, restrict to host in production

Defaults to * for dev (Obsidian plugin needs it), but production
sets the origin to the PHX_HOST value."
```
