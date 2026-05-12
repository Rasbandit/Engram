# AWS KMS Phase 2 — Boot Canary Polymorphism + KMS Telemetry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `BootCanary.verify!/0` dispatch through the configured `KeyProvider` (Local OR AwsKms), gate AwsKms boots with a `describe_key` ping, and emit `[:engram, :crypto, :kms, :request|:failure]` telemetry on every AWS KMS request so production has observability before Phase 3 migration.

**Architecture:** Two new behaviour callbacks (`boot_check/0`, `unwrap_dek_no_fallback/2`) keep BootCanary provider-agnostic. The `Engram.AwsKms.ExAws` module wraps every AWS call in `:telemetry.span/3`-style request + failure emit. Behaviour is opt-in: `KEY_PROVIDER=local` paths remain bit-for-bit identical so deploy is dead-loaded for SaaS until Phase 3 + 4.

**Tech Stack:** Elixir/Phoenix, ExAws.KMS, `:telemetry`, Mox (via `Engram.AwsKmsMock`), ExUnit + `:telemetry.attach` for event assertions.

---

## File Structure

| File | Why |
|------|-----|
| `lib/engram/crypto/key_provider.ex` (modify) | Add `boot_check/0` + `unwrap_dek_no_fallback/2` callbacks. |
| `lib/engram/crypto/key_provider/local.ex` (modify) | Implement both new callbacks; `unwrap_dek_no_fallback/2` delegates to existing `unwrap_dek_current_only/2`; `boot_check/0` returns `:ok`. |
| `lib/engram/crypto/key_provider/aws_kms.ex` (modify) | Implement both new callbacks; `boot_check/0` calls `aws_kms().describe_key()`; `unwrap_dek_no_fallback/2` delegates to `unwrap_dek/2`. |
| `lib/engram/crypto/boot_canary.ex` (modify) | Drop direct `Local.unwrap_dek_current_only/2` call; route through `Resolver.provider()` → `provider.boot_check()` → `provider.unwrap_dek_no_fallback/2`. Tag `[:engram, :crypto, :boot_canary]` telemetry with `provider:`. |
| `lib/engram/aws_kms/ex_aws.ex` (modify) | Wrap each `ExAws.request/2` in `:telemetry.execute([:engram, :crypto, :kms, :request], ...)` measuring `duration_us`; emit `[:engram, :crypto, :kms, :failure]` on error tuple. |
| `test/engram/crypto/boot_canary_test.exs` (modify) | New tests: AwsKms branch uses Mox to stub `describe_key`/`decrypt`; assert `provider:` metadata; assert raise when `describe_key` fails. |
| `test/engram/aws_kms/ex_aws_test.exs` (modify) | Add telemetry assertion tests for `:request` (ok + error) and `:failure` events on each op. |
| `test/engram/crypto/provider_conformance_test.exs` (modify) | Add `boot_check` + `unwrap_dek_no_fallback` round-trip assertions to the parametrised conformance loop. |

---

## Task 1 — Add `boot_check/0` + `unwrap_dek_no_fallback/2` behaviour callbacks

**Files:**
- Modify: `lib/engram/crypto/key_provider.ex`

- [ ] **Step 1: Edit behaviour to add the two new callbacks**

```elixir
# Append inside the `defmodule Engram.Crypto.KeyProvider do … end` block,
# above the `@doc "Default DEK generator …"` line.
@doc """
Provider-specific pre-flight performed once at app boot, BEFORE the
boot canary unwrap. Implementations that need to validate connectivity
or credentials with their key source SHOULD do it here.

- `Local` returns `:ok` (no external state).
- `AwsKms` issues a single `DescribeKey` call against the configured
  CMK — surfaces wrong-ARN, IAM-denied, wrong-region misconfiguration
  before the first user request hits the hot path.
"""
@callback boot_check() :: :ok | {:error, term()}

@doc """
Unwrap `wrapped` without any provider-internal fallback. Used by the
boot canary so that a misconfigured master key cannot be silently
rescued by a `_PREVIOUS` rotation slot. Providers without a fallback
concept (e.g. AwsKms) MAY delegate to `unwrap_dek/2`.
"""
@callback unwrap_dek_no_fallback(wrapped(), ctx()) ::
            {:ok, dek()} | {:error, term()}
```

- [ ] **Step 2: Commit (compile-only — implementations land in next tasks)**

```bash
git add lib/engram/crypto/key_provider.ex
git commit -m "feat(crypto): add boot_check + unwrap_dek_no_fallback callbacks"
```

Expected: `mix compile --warnings-as-errors --force` reports `Engram.Crypto.KeyProvider.Local`/`AwsKms` missing the new callbacks — that's deliberate; next tasks add them.

---

## Task 2 — Implement callbacks on `KeyProvider.Local`

**Files:**
- Modify: `lib/engram/crypto/key_provider/local.ex`
- Modify: `test/engram/crypto/key_provider/local_test.exs`

- [ ] **Step 1: Write failing test — `boot_check/0` returns `:ok`**

```elixir
# test/engram/crypto/key_provider/local_test.exs — add a new describe block
describe "boot_check/0" do
  test "returns :ok (Local provider has no external state to verify)" do
    assert :ok = Engram.Crypto.KeyProvider.Local.boot_check()
  end
end

describe "unwrap_dek_no_fallback/2" do
  setup do
    Application.put_env(
      :engram,
      :encryption_master_key,
      Base.encode64(:crypto.strong_rand_bytes(32))
    )

    :ok
  end

  test "round-trips a freshly-wrapped DEK" do
    dek = :crypto.strong_rand_bytes(32)
    {:ok, wrapped} = Engram.Crypto.KeyProvider.Local.wrap_dek(dek, %{user_id: 7})

    assert {:ok, ^dek} =
             Engram.Crypto.KeyProvider.Local.unwrap_dek_no_fallback(
               wrapped,
               %{user_id: 7}
             )
  end

  test "does NOT consult _PREVIOUS — wrong master key returns :invalid_wrapping" do
    dek = :crypto.strong_rand_bytes(32)
    {:ok, wrapped} = Engram.Crypto.KeyProvider.Local.wrap_dek(dek, %{user_id: 7})

    Application.put_env(
      :engram,
      :encryption_master_key,
      Base.encode64(:crypto.strong_rand_bytes(32))
    )

    assert {:error, :invalid_wrapping} =
             Engram.Crypto.KeyProvider.Local.unwrap_dek_no_fallback(
               wrapped,
               %{user_id: 7}
             )
  end
end
```

- [ ] **Step 2: Run tests, see them fail**

```bash
mix test test/engram/crypto/key_provider/local_test.exs --only describe:"boot_check/0" --only describe:"unwrap_dek_no_fallback/2"
```

Expected: `UndefinedFunctionError: function Engram.Crypto.KeyProvider.Local.boot_check/0 is undefined`.

- [ ] **Step 3: Implement both callbacks**

```elixir
# lib/engram/crypto/key_provider/local.ex — add near the other @impl true blocks
@impl true
def boot_check, do: :ok

@impl true
def unwrap_dek_no_fallback(blob, %{user_id: uid}) when is_binary(blob) do
  case unwrap_dek_current_only(blob, user_id: uid) do
    {:ok, dek} -> {:ok, dek}
    {:error, reason} -> {:error, reason}
  end
end
```

(`unwrap_dek_current_only/2` accepts `user_id: :canary | integer()`; the behaviour callback narrows it to the ctx map and forwards.)

- [ ] **Step 4: Run tests, see them pass**

```bash
mix test test/engram/crypto/key_provider/local_test.exs
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/engram/crypto/key_provider/local.ex test/engram/crypto/key_provider/local_test.exs
git commit -m "feat(crypto): implement boot_check + unwrap_dek_no_fallback on Local"
```

---

## Task 3 — Implement callbacks on `KeyProvider.AwsKms`

**Files:**
- Modify: `lib/engram/crypto/key_provider/aws_kms.ex`
- Modify: `test/engram/crypto/key_provider/aws_kms_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
# test/engram/crypto/key_provider/aws_kms_test.exs — append inside the existing
# test module. Mox is already imported and Engram.AwsKmsMock is in test config.

describe "boot_check/0" do
  test "returns :ok when describe_key succeeds" do
    expect(Engram.AwsKmsMock, :describe_key, fn -> :ok end)
    assert :ok = Engram.Crypto.KeyProvider.AwsKms.boot_check()
  end

  test "propagates an error tuple when describe_key fails" do
    expect(Engram.AwsKmsMock, :describe_key, fn -> {:error, :access_denied} end)

    assert {:error, :access_denied} =
             Engram.Crypto.KeyProvider.AwsKms.boot_check()
  end
end

describe "unwrap_dek_no_fallback/2" do
  test "delegates to unwrap_dek/2 (AwsKms has no fallback concept)" do
    dek = :crypto.strong_rand_bytes(32)

    expect(Engram.AwsKmsMock, :decrypt, fn _ct, %{"user_id" => "7", "purpose" => "dek_wrap"} ->
      {:ok, dek}
    end)

    blob = <<0xAA, 0x01, :crypto.strong_rand_bytes(48)::binary>>

    assert {:ok, ^dek} =
             Engram.Crypto.KeyProvider.AwsKms.unwrap_dek_no_fallback(
               blob,
               %{user_id: 7}
             )
  end
end
```

- [ ] **Step 2: Run tests, see them fail**

```bash
mix test test/engram/crypto/key_provider/aws_kms_test.exs
```

Expected: `UndefinedFunctionError` for `boot_check/0` and `unwrap_dek_no_fallback/2`.

- [ ] **Step 3: Implement both callbacks**

```elixir
# lib/engram/crypto/key_provider/aws_kms.ex — alongside the other @impl true clauses
@impl true
def boot_check, do: aws_kms().describe_key()

@impl true
def unwrap_dek_no_fallback(<<@provider_tag, @payload_v1, _::binary>> = blob, ctx),
  do: unwrap_dek(blob, ctx)

def unwrap_dek_no_fallback(_other, _ctx), do: {:error, :malformed_wrapped_blob}
```

- [ ] **Step 4: Run tests, see them pass**

```bash
mix test test/engram/crypto/key_provider/aws_kms_test.exs
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/engram/crypto/key_provider/aws_kms.ex test/engram/crypto/key_provider/aws_kms_test.exs
git commit -m "feat(crypto): implement boot_check + unwrap_dek_no_fallback on AwsKms"
```

---

## Task 4 — Extend conformance suite

**Files:**
- Modify: `test/engram/crypto/provider_conformance_test.exs`

- [ ] **Step 1: Add new conformance tests inside the `for provider <- @providers` loop**

```elixir
test "#{inspect(provider)}: boot_check returns :ok in happy path" do
  if unquote(provider) == Engram.Crypto.KeyProvider.AwsKms do
    stub_aws_kms_roundtrip()
    stub(Engram.AwsKmsMock, :describe_key, fn -> :ok end)
  end

  assert :ok = unquote(provider).boot_check()
end

test "#{inspect(provider)}: unwrap_dek_no_fallback round-trips wrapped DEK" do
  if unquote(provider) == Engram.Crypto.KeyProvider.AwsKms, do: stub_aws_kms_roundtrip()

  dek = unquote(provider).generate_dek()
  ctx = %{user_id: 1}
  {:ok, wrapped} = unquote(provider).wrap_dek(dek, ctx)
  assert {:ok, ^dek} = unquote(provider).unwrap_dek_no_fallback(wrapped, ctx)
end
```

- [ ] **Step 2: Run the conformance suite**

```bash
mix test test/engram/crypto/provider_conformance_test.exs
```

Expected: PASS (all parametrised tests, both providers).

- [ ] **Step 3: Commit**

```bash
git add test/engram/crypto/provider_conformance_test.exs
git commit -m "test(crypto): extend conformance with boot_check + unwrap_dek_no_fallback"
```

---

## Task 5 — Wire `BootCanary` through the resolved provider

**Files:**
- Modify: `lib/engram/crypto/boot_canary.ex`
- Modify: `test/engram/crypto/boot_canary_test.exs`

- [ ] **Step 1: Write failing tests covering AwsKms branch + provider tag**

```elixir
# test/engram/crypto/boot_canary_test.exs — add a new describe block at the bottom

describe "verify!/0 — AwsKms provider" do
  import Mox
  setup :verify_on_exit!

  setup do
    prev_provider = Application.get_env(:engram, :key_provider)
    prev_client = Application.get_env(:engram, :aws_kms_client)
    Application.put_env(:engram, :key_provider, Engram.Crypto.KeyProvider.AwsKms)
    Application.put_env(:engram, :aws_kms_client, Engram.AwsKmsMock)

    on_exit(fn ->
      Application.put_env(:engram, :key_provider, prev_provider)
      Application.put_env(:engram, :aws_kms_client, prev_client)
    end)

    :ok
  end

  test "raises when boot_check (DescribeKey) fails" do
    # Insert a placeholder canary blob first so verify! reaches the boot_check path.
    Engram.Repo.insert_all("system_canaries", [
      %{
        wrapped_dek: <<0xAA, 0x01, :crypto.strong_rand_bytes(48)::binary>>,
        dek_sha256: :crypto.hash(:sha256, <<0>>),
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
    ])

    expect(Engram.AwsKmsMock, :describe_key, fn -> {:error, :access_denied} end)

    assert_raise RuntimeError, ~r/describe_key/i, fn ->
      Engram.Crypto.BootCanary.verify!()
    end
  end

  test "tags :ok telemetry with provider: :aws_kms" do
    dek = :crypto.strong_rand_bytes(32)
    sha = :crypto.hash(:sha256, dek)
    blob = <<0xAA, 0x01, :crypto.strong_rand_bytes(48)::binary>>

    Engram.Repo.insert_all("system_canaries", [
      %{
        wrapped_dek: blob,
        dek_sha256: sha,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
    ])

    stub(Engram.AwsKmsMock, :describe_key, fn -> :ok end)
    stub(Engram.AwsKmsMock, :decrypt, fn _ct, _ctx -> {:ok, dek} end)

    :telemetry.attach(
      "boot-canary-aws",
      [:engram, :crypto, :boot_canary],
      fn _n, _m, meta, _ -> send(self(), {:canary, meta}) end,
      nil
    )

    try do
      assert :ok = Engram.Crypto.BootCanary.verify!()
      assert_received {:canary, %{status: :ok, provider: :aws_kms}}
    after
      :telemetry.detach("boot-canary-aws")
    end
  end
end
```

- [ ] **Step 2: Run tests, see them fail**

```bash
mix test test/engram/crypto/boot_canary_test.exs
```

Expected: First test fails because verify! still calls Local directly; second fails because metadata is missing `provider:`.

- [ ] **Step 3: Refactor BootCanary to dispatch via Resolver**

Replace the body of `verify!/0` in `lib/engram/crypto/boot_canary.ex`:

```elixir
@spec verify!() :: :ok
def verify! do
  provider = Engram.Crypto.KeyProvider.Resolver.provider()

  case provider.boot_check() do
    :ok ->
      :ok

    {:error, reason} ->
      :telemetry.execute(
        [:engram, :crypto, :boot_canary],
        %{count: 1},
        %{status: :failed, provider: provider.name(), reason_label: reason_label(reason)}
      )

      raise """
      boot canary describe_key/boot_check failed: #{inspect(reason)}.
      Verify the configured key provider is reachable and the IAM /
      credentials are correct.
      """
  end

  case fetch_latest() do
    nil ->
      Logger.warning("boot_canary: no canary row, provisioning fresh", category: :boot_canary)
      provision!(provider)

      :telemetry.execute(
        [:engram, :crypto, :boot_canary],
        %{count: 1},
        %{status: :provisioned, provider: provider.name()}
      )

      :ok

    %{wrapped_dek: blob, dek_sha256: expected_hash} ->
      case provider.unwrap_dek_no_fallback(blob, %{user_id: canary_user_id()}) do
        {:ok, plaintext_dek} ->
          if :crypto.hash(:sha256, plaintext_dek) == expected_hash do
            :telemetry.execute(
              [:engram, :crypto, :boot_canary],
              %{count: 1},
              %{status: :ok, provider: provider.name()}
            )

            :ok
          else
            :telemetry.execute(
              [:engram, :crypto, :boot_canary],
              %{count: 1},
              %{status: :failed, provider: provider.name(), reason_label: "sha_mismatch"}
            )

            raise """
            boot canary unwrap returned a plaintext that does not match the
            recorded SHA256. This indicates a corrupted canary row, not a
            wrong-key situation. Inspect the system_canaries table.
            """
          end

        {:error, reason} ->
          :telemetry.execute(
            [:engram, :crypto, :boot_canary],
            %{count: 1},
            %{status: :failed, provider: provider.name(), reason_label: reason_label(reason)}
          )

          raise """
          boot canary unwrap failed: #{inspect(reason)} via provider #{provider.name()}.
          Verify env vars and re-run rotation if a master-key cutover is in progress.
          """
      end
  end
end
```

Also update `provision!/0` to take the active provider and use a sentinel integer user_id (so AwsKms's `encryption_context` accepts it):

```elixir
@canary_user_id 0

defp canary_user_id, do: @canary_user_id

@doc false
@spec provision!(module()) :: :ok
def provision!(provider \\ Engram.Crypto.KeyProvider.Resolver.provider()) do
  dek = :crypto.strong_rand_bytes(@canary_dek_size)
  {:ok, wrapped} = provider.wrap_dek(dek, %{user_id: canary_user_id()})
  sha = :crypto.hash(:sha256, dek)
  now = DateTime.utc_now()

  {1, _} =
    Repo.insert_all(
      "system_canaries",
      [
        %{
          wrapped_dek: wrapped,
          dek_sha256: sha,
          inserted_at: now,
          updated_at: now
        }
      ]
    )

  :ok
end
```

Remove the `alias Engram.Crypto.KeyProvider.Local` and replace it with `alias Engram.Crypto.KeyProvider.Resolver` (only needed inside `provision!/1`'s default arg).

- [ ] **Step 4: Update existing Local-branch tests for the new `provider:` metadata**

```elixir
# Inside `describe "verify!/0"` — every assert_received now expects provider: :local
assert_received {:canary, %{status: :provisioned, provider: :local}}
# … and similarly for :ok / :failed assertions.
```

- [ ] **Step 5: Run full canary test file, see PASS**

```bash
mix test test/engram/crypto/boot_canary_test.exs
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/engram/crypto/boot_canary.ex test/engram/crypto/boot_canary_test.exs
git commit -m "feat(crypto): BootCanary dispatches through configured provider"
```

---

## Task 6 — Telemetry events on every AWS KMS call

**Files:**
- Modify: `lib/engram/aws_kms/ex_aws.ex`
- Modify: `test/engram/aws_kms/ex_aws_test.exs`

- [ ] **Step 1: Write failing telemetry tests**

```elixir
# test/engram/aws_kms/ex_aws_test.exs — append a new describe block

describe "telemetry" do
  test "emits :request event with duration_us, op, status on successful encrypt", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/", fn conn ->
      Plug.Conn.resp(conn, 200, ~s({"CiphertextBlob":"#{Base.encode64("ct")}"}))
    end)

    :telemetry.attach(
      "kms-req-ok",
      [:engram, :crypto, :kms, :request],
      fn _name, meas, meta, _ -> send(self(), {:tel_req, meas, meta}) end,
      nil
    )

    try do
      assert {:ok, "ct"} =
               Engram.AwsKms.ExAws.encrypt("pt", %{"user_id" => "1", "purpose" => "dek_wrap"})

      assert_received {:tel_req, %{duration_us: dur}, %{op: :encrypt, status: :ok}}
      assert is_integer(dur) and dur >= 0
    after
      :telemetry.detach("kms-req-ok")
    end
  end

  test "emits :failure event with error_class on AccessDenied", %{bypass: bypass} do
    Bypass.expect(bypass, "POST", "/", fn conn ->
      Plug.Conn.resp(
        conn,
        400,
        ~s({"__type":"AccessDeniedException","message":"nope"})
      )
    end)

    :telemetry.attach_many(
      "kms-failure",
      [
        [:engram, :crypto, :kms, :request],
        [:engram, :crypto, :kms, :failure]
      ],
      fn name, _meas, meta, _ -> send(self(), {name, meta}) end,
      nil
    )

    try do
      assert {:error, :access_denied} =
               Engram.AwsKms.ExAws.encrypt("pt", %{"user_id" => "1", "purpose" => "dek_wrap"})

      assert_received {[:engram, :crypto, :kms, :request],
                       %{op: :encrypt, status: :error, error_class: :access_denied}}

      assert_received {[:engram, :crypto, :kms, :failure],
                       %{op: :encrypt, error_class: :access_denied}}
    after
      :telemetry.detach("kms-failure")
    end
  end
end
```

- [ ] **Step 2: Run tests, see them fail**

```bash
mix test test/engram/aws_kms/ex_aws_test.exs --only describe:telemetry
```

Expected: assert_received timeouts — no telemetry currently emitted.

- [ ] **Step 3: Add a private telemetry helper + wrap each op**

```elixir
# lib/engram/aws_kms/ex_aws.ex — add near the top of the module body
@event_request [:engram, :crypto, :kms, :request]
@event_failure [:engram, :crypto, :kms, :failure]

defp instrument(op, fun) do
  start = System.monotonic_time()

  result =
    try do
      fun.()
    rescue
      e ->
        emit_failure(op, :crash)
        reraise e, __STACKTRACE__
    end

  duration_us = System.convert_time_unit(System.monotonic_time() - start, :native, :microsecond)

  case result do
    {:ok, _} = ok ->
      :telemetry.execute(@event_request, %{duration_us: duration_us}, %{op: op, status: :ok})
      ok

    {:error, reason} = err ->
      error_class = classify_for_telemetry(reason)

      :telemetry.execute(
        @event_request,
        %{duration_us: duration_us},
        %{op: op, status: :error, error_class: error_class}
      )

      emit_failure(op, error_class)
      err
  end
end

defp emit_failure(op, error_class) do
  :telemetry.execute(@event_failure, %{count: 1}, %{op: op, error_class: error_class})
end

defp classify_for_telemetry(reason) when is_atom(reason), do: reason
defp classify_for_telemetry({:aws, _code, _msg}), do: :other
defp classify_for_telemetry(_other), do: :other
```

Then wrap each public function. Example for `encrypt/2`:

```elixir
def encrypt(plaintext, enc_ctx) do
  instrument(:encrypt, fn ->
    key_id = key_id!()

    key_id
    |> ExAws.KMS.encrypt(Base.encode64(plaintext), encryption_context: enc_ctx)
    |> ExAws.request(@ex_aws_opts)
    |> case do
      {:ok, %{"CiphertextBlob" => ct_b64}} -> {:ok, Base.decode64!(ct_b64)}
      {:error, reason} -> {:error, classify(reason)}
    end
  end)
end
```

Apply the same `instrument(:decrypt, fn -> … end)` / `instrument(:re_encrypt, fn -> … end)` / `instrument(:describe_key, fn -> … end)` wrapper to the other three callbacks.

- [ ] **Step 4: Run tests, see them pass**

```bash
mix test test/engram/aws_kms/ex_aws_test.exs
```

Expected: all PASS (existing 8 + new 2).

- [ ] **Step 5: Commit**

```bash
git add lib/engram/aws_kms/ex_aws.ex test/engram/aws_kms/ex_aws_test.exs
git commit -m "feat(crypto): emit :kms :request/:failure telemetry on every AWS call"
```

---

## Task 7 — Lint + full suite gate

- [ ] **Step 1: Run the full quality stack**

```bash
mix format --check-formatted && \
mix compile --warnings-as-errors --force && \
mix credo --strict --mute-exit-status && \
mix sobelow --exit low && \
mix test
```

Expected: every gate passes; full test suite green.

- [ ] **Step 2: Commit any formatter-only fixups**

If `mix format` rewrote files, commit:

```bash
git add -A
git commit -m "chore: mix format"
```

- [ ] **Step 3: Push and open PR**

```bash
git push -u origin feat/aws-kms-phase-2-boot-canary
gh pr create --title "feat(crypto): AWS KMS Phase 2 — boot canary polymorphism + KMS telemetry" \
  --body "$(cat <<'EOF'
## Summary
- Adds `boot_check/0` and `unwrap_dek_no_fallback/2` callbacks to `Engram.Crypto.KeyProvider`.
- `BootCanary.verify!/0` now dispatches through the configured provider — Local keeps its no-`_PREVIOUS` semantics; AwsKms gates boot with a `DescribeKey` ping.
- Every `Engram.AwsKms.ExAws` call emits `[:engram, :crypto, :kms, :request]` (duration + status) and `[:engram, :crypto, :kms, :failure]` (error_class).
- Production behaviour unchanged: `KEY_PROVIDER=local` still default in `config/runtime.exs`; new code is dead-loaded.

## Test plan
- [ ] `mix test` green (new conformance + canary + telemetry tests).
- [ ] `mix credo --strict`, `mix sobelow --exit low`, `mix dialyzer` clean (CI).
- [ ] Boot the app locally with `KEY_PROVIDER=local`; canary telemetry includes `provider: :local`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Phase 2 Out of Scope

- ProviderMigration state machine — Phase 3.
- IAM policy creation, Fly secrets, KMS cutover runbook — Phase 4.
- `MasterRotation.rotate_canary/0` extension to wrap via AwsKms — happens implicitly through `Resolver.provider().wrap_dek/2` once Phase 4 flips `KEY_PROVIDER`. No code change required here.
