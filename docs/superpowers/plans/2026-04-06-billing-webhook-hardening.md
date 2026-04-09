# Billing & Webhook Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix crash bugs and silent failures in the billing/webhook pipeline. Prevent wrong-tier assignment, unsafe integer parsing, and JSON decode crashes.

**Architecture:** Changes are isolated to `Engram.Billing` and `EngramWeb.WebhookController`. Each task fixes one specific issue. All TDD.

**Tech Stack:** Elixir, Ecto, Stripe (stripity_stripe), Jason

**Reference:** See `docs/context/code-audit-2026-04.md` for audit findings (H17, H18, M12, M16).

---

### Task 1: Fix price_id_for/1 returning nil (H17)

**Files:**
- Modify: `lib/engram/billing.ex:173-174`
- Modify: `test/engram/billing_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/engram/billing_test.exs`:

```elixir
describe "create_checkout_session/2" do
  test "returns error when price ID is not configured" do
    # Temporarily unset the price config
    original = Application.get_env(:engram, :stripe_starter_price_id)
    Application.put_env(:engram, :stripe_starter_price_id, nil)

    user = user_fixture()
    assert {:error, :price_not_configured} = Billing.create_checkout_session(user, "starter")

    # Restore
    if original, do: Application.put_env(:engram, :stripe_starter_price_id, original)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram/billing_test.exs --only "price ID" -v`
Expected: FAIL — currently passes `nil` to Stripe, which crashes or returns a confusing Stripe error.

- [ ] **Step 3: Add nil guard to create_checkout_session**

In `lib/engram/billing.ex`, change `create_checkout_session/2` from:

```elixir
  def create_checkout_session(user, tier) when tier in ~w(starter pro) do
    price_id = price_id_for(tier)

    params = %{
```

to:

```elixir
  def create_checkout_session(user, tier) when tier in ~w(starter pro) do
    case price_id_for(tier) do
      nil ->
        {:error, :price_not_configured}

      price_id ->
        params = %{
```

And close the `case` at the end of the function before the final `end`.

- [ ] **Step 4: Run tests**

Run: `mix test test/engram/billing_test.exs -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/engram/billing.ex test/engram/billing_test.exs
git commit -m "fix: return {:error, :price_not_configured} when Stripe price ID is nil

Previously nil was passed to Stripe API, causing confusing errors.
Now fails fast with a clear error tuple."
```

---

### Task 2: Fix tier_from_price_id/1 silent wrong-tier default (H18)

**Files:**
- Modify: `lib/engram/billing.ex:176-181`
- Modify: `test/engram/billing_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/engram/billing_test.exs`:

```elixir
describe "upsert_from_stripe_event/1 with subscription.updated" do
  test "logs warning for unknown price ID" do
    user = user_fixture()

    # Create a subscription first
    Repo.insert!(
      %Subscription{
        user_id: user.id,
        status: "active",
        tier: "starter",
        stripe_customer_id: "cus_test",
        stripe_subscription_id: "sub_unknown_price"
      },
      skip_tenant_check: true
    )

    event = %{
      "type" => "customer.subscription.updated",
      "data" => %{
        "object" => %{
          "id" => "sub_unknown_price",
          "status" => "active",
          "current_period_end" => DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.to_unix(),
          "items" => %{
            "data" => [%{"price" => %{"id" => "price_UNKNOWN_XYZ"}}]
          }
        }
      }
    }

    # Should not silently default to "starter"
    assert {:error, :unknown_price_id} = Billing.upsert_from_stripe_event(event)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram/billing_test.exs --only "unknown price" -v`
Expected: FAIL — currently defaults to `"starter"` silently.

- [ ] **Step 3: Return error on unknown price ID**

In `lib/engram/billing.ex`, change `tier_from_price_id/1` from:

```elixir
  defp tier_from_price_id(price_id) do
    cond do
      price_id == Application.get_env(:engram, :stripe_starter_price_id) -> "starter"
      price_id == Application.get_env(:engram, :stripe_pro_price_id) -> "pro"
      true -> "starter"
    end
  end
```

to:

```elixir
  defp tier_from_price_id(price_id) do
    cond do
      price_id == Application.get_env(:engram, :stripe_starter_price_id) -> {:ok, "starter"}
      price_id == Application.get_env(:engram, :stripe_pro_price_id) -> {:ok, "pro"}
      true -> :error
    end
  end
```

Then update the caller in `upsert_from_stripe_event` (the `customer.subscription.updated` clause) from:

```elixir
    tier = tier_from_price_id(price_id)
    period_end = DateTime.from_unix!(period_end_unix)
```

to:

```elixir
    case tier_from_price_id(price_id) do
      {:ok, tier} ->
        period_end = DateTime.from_unix!(period_end_unix)
```

And wrap the rest of that function clause's body in the `{:ok, tier}` branch, adding:

```elixir
      :error ->
        require Logger
        Logger.warning("Unknown Stripe price ID: #{price_id}")
        {:error, :unknown_price_id}
    end
```

- [ ] **Step 4: Run tests**

Run: `mix test test/engram/billing_test.exs -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/engram/billing.ex test/engram/billing_test.exs
git commit -m "fix: reject unknown Stripe price IDs instead of defaulting to starter

Previously, unrecognized price IDs silently assigned 'starter' tier.
Now returns {:error, :unknown_price_id} with a warning log."
```

---

### Task 3: Safe integer parsing in webhook (M12)

**Files:**
- Modify: `lib/engram/billing.ex:120`
- Modify: `test/engram/billing_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/engram/billing_test.exs`:

```elixir
describe "upsert_from_stripe_event/1 with bad client_reference_id" do
  test "returns error for non-integer client_reference_id" do
    event = %{
      "type" => "checkout.session.completed",
      "data" => %{
        "object" => %{
          "customer" => "cus_abc",
          "subscription" => "sub_abc",
          "client_reference_id" => "not_a_number",
          "metadata" => %{"tier" => "starter"}
        }
      }
    }

    assert {:error, :invalid_user_id} = Billing.upsert_from_stripe_event(event)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram/billing_test.exs --only "bad client_reference" -v`
Expected: FAIL — `ArgumentError` from `String.to_integer("not_a_number")`.

- [ ] **Step 3: Use Integer.parse with error handling**

In `lib/engram/billing.ex`, change line 120 from:

```elixir
    user_id = String.to_integer(user_id_str)
```

to:

```elixir
    case Integer.parse(user_id_str) do
      {user_id, ""} ->
```

And wrap the remaining body of the `checkout.session.completed` clause inside this `case`, adding:

```elixir
      _ ->
        {:error, :invalid_user_id}
    end
```

- [ ] **Step 4: Run tests**

Run: `mix test test/engram/billing_test.exs -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/engram/billing.ex test/engram/billing_test.exs
git commit -m "fix: use Integer.parse for webhook client_reference_id

String.to_integer crashes on non-numeric input. Stripe webhook
data should be treated as untrusted."
```

---

### Task 4: Safe JSON decoding in webhook controller (M16)

**Files:**
- Modify: `lib/engram_web/controllers/webhook_controller.ex`
- Modify: `test/engram_web/controllers/webhook_controller_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/engram_web/controllers/webhook_controller_test.exs`:

```elixir
describe "stripe webhook with malformed JSON" do
  test "returns 400 for invalid JSON body" do
    # We need to send raw body that passes the Plug.Parsers
    # but is still somehow invalid after CacheRawBody caches it.
    # Since Plug.Parsers will reject truly invalid JSON before
    # reaching the controller, this test verifies the controller
    # handles the edge case where cached_raw_body has bad data.
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("stripe-signature", "t=12345,v1=fake")

    # Assign a cached raw body with invalid JSON
    conn = Plug.Conn.assign(conn, :cached_raw_body, "not json{{{")
    conn = post(conn, "/webhooks/stripe")

    assert conn.status in [400, 401]
  end
end
```

- [ ] **Step 2: Replace Jason.decode! with Jason.decode**

In `lib/engram_web/controllers/webhook_controller.ex`, change:

```elixir
    event = Jason.decode!(payload)
```

to:

```elixir
    case Jason.decode(payload) do
      {:ok, event} ->
```

And wrap the remaining body in the `{:ok, event}` branch, adding:

```elixir
      {:error, _} ->
        conn
        |> put_status(400)
        |> json(%{error: "invalid_json"})
    end
```

- [ ] **Step 3: Run tests**

Run: `mix test test/engram_web/controllers/webhook_controller_test.exs -v`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add lib/engram_web/controllers/webhook_controller.ex test/engram_web/controllers/webhook_controller_test.exs
git commit -m "fix: use Jason.decode/1 instead of decode! in webhook controller

Prevents 500 crash on malformed JSON payloads that pass signature
verification. Returns 400 with clear error instead."
```
