# Crash Bugs & Correctness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix runtime crash bugs in path sanitizer, billing, sync channel, and MCP handlers. These are all bugs that will cause 500s or process crashes under normal usage.

**Architecture:** Each task is independent. Fixes are in business logic and channel layers. All changes are TDD — write failing test first, then fix.

**Tech Stack:** Elixir, Phoenix Channels, Ecto, Oban

**Reference:** See `docs/context/code-audit-2026-04.md` for audit findings (C3, C4, H8, H9, H10, M29, M30).

---

### Task 1: Fix path sanitizer filename corruption (C3)

**Files:**
- Modify: `lib/engram/notes/path_sanitizer.ex:41`
- Modify: `test/engram/notes/path_sanitizer_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/engram/notes/path_sanitizer_test.exs`:

```elixir
test "preserves double dots within filenames" do
  assert PathSanitizer.sanitize("notes/v2..3-notes.md") == "notes/v2..3-notes.md"
end

test "preserves ellipsis in filenames" do
  assert PathSanitizer.sanitize("notes/wait...what.md") == "notes/wait...what.md"
end

test "still rejects standalone traversal segments" do
  assert PathSanitizer.sanitize("notes/../secret.md") == "notes/secret.md"
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram/notes/path_sanitizer_test.exs -v`
Expected: FAIL — `"v2..3-notes.md"` becomes `"v23-notes.md"`.

- [ ] **Step 3: Remove the destructive String.replace line**

In `lib/engram/notes/path_sanitizer.ex`, change `clean_segment/1` from:

```elixir
  defp clean_segment(segment) do
    segment
    |> String.trim()
    |> String.replace("..", "")
    |> collapse_spaces()
    |> truncate_segment(255)
    |> reject_traversal()
  end
```

to:

```elixir
  defp clean_segment(segment) do
    segment
    |> String.trim()
    |> collapse_spaces()
    |> truncate_segment(255)
    |> reject_traversal()
  end
```

- [ ] **Step 4: Run tests**

Run: `mix test test/engram/notes/path_sanitizer_test.exs -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/engram/notes/path_sanitizer.ex test/engram/notes/path_sanitizer_test.exs
git commit -m "fix: remove destructive String.replace('..', '') from path sanitizer

The replace was corrupting legitimate filenames like 'v2..3-notes.md'.
The reject_traversal/1 guard already handles standalone '..' segments."
```

---

### Task 2: Fix billing tier atom crash (C4)

**Files:**
- Modify: `lib/engram/billing.ex:18-26`
- Modify: `test/engram/billing_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/engram/billing_test.exs`:

```elixir
describe "tier/1" do
  test "returns :none for user with unknown tier string" do
    user = user_fixture()

    Repo.insert!(
      %Subscription{
        user_id: user.id,
        status: "active",
        tier: "enterprise",
        stripe_customer_id: "cus_test",
        stripe_subscription_id: "sub_test"
      },
      skip_tenant_check: true
    )

    # Should return :none, not crash with ArgumentError
    assert Billing.tier(user) == :none
  end

  test "returns correct atom for known tiers" do
    user = user_fixture()

    for {tier_str, tier_atom} <- [{"trial", :trial}, {"starter", :starter}, {"pro", :pro}] do
      Repo.delete_all(Subscription, skip_tenant_check: true)

      Repo.insert!(
        %Subscription{
          user_id: user.id,
          status: "active",
          tier: tier_str,
          stripe_customer_id: "cus_test",
          stripe_subscription_id: "sub_test"
        },
        skip_tenant_check: true
      )

      assert Billing.tier(user) == tier_atom
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram/billing_test.exs -v`
Expected: FAIL — `String.to_existing_atom("enterprise")` raises `ArgumentError`.

- [ ] **Step 3: Replace to_existing_atom with hardcoded map**

In `lib/engram/billing.ex`, change lines 12-26 from:

```elixir
  @doc """
  Returns the user's effective tier as an atom.
  Users without a subscription (or with a canceled one) are :none.
  """
  def tier(user) do
    case get_subscription(user) do
      %Subscription{status: status, tier: tier} when status in ~w(active past_due trialing) ->
        String.to_existing_atom(tier)

      _ ->
        :none
    end
  end
```

to:

```elixir
  @tier_atoms %{"trial" => :trial, "starter" => :starter, "pro" => :pro}

  @doc """
  Returns the user's effective tier as an atom.
  Users without a subscription (or with a canceled one) are :none.
  """
  def tier(user) do
    case get_subscription(user) do
      %Subscription{status: status, tier: tier} when status in ~w(active past_due trialing) ->
        Map.get(@tier_atoms, tier, :none)

      _ ->
        :none
    end
  end
```

- [ ] **Step 4: Run tests**

Run: `mix test test/engram/billing_test.exs -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/engram/billing.ex test/engram/billing_test.exs
git commit -m "fix: replace String.to_existing_atom with safe map lookup in Billing.tier/1

Unexpected tier strings now return :none instead of crashing with
ArgumentError. Uses a hardcoded map for the known tier set."
```

---

### Task 3: Fix SyncChannel.delete_note crash (H9)

**Files:**
- Modify: `lib/engram_web/channels/sync_channel.ex:80-92`
- Modify: `test/engram_web/channels/sync_channel_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/engram_web/channels/sync_channel_test.exs`:

```elixir
describe "delete_note" do
  test "deletes an existing note and broadcasts", %{socket: socket, user: user} do
    # Create a note first
    {:ok, _note} =
      Notes.upsert_note(user, %{
        "path" => "Test/delete-me.md",
        "content" => "# Delete Me",
        "mtime" => 1_709_234_567.0
      })

    ref = push(socket, "delete_note", %{"path" => "Test/delete-me.md"})
    assert_reply ref, :ok, %{"deleted" => true}
  end

  test "deletes a non-existent note without crashing", %{socket: socket} do
    ref = push(socket, "delete_note", %{"path" => "nonexistent.md"})
    assert_reply ref, :ok, %{"deleted" => true}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram_web/channels/sync_channel_test.exs -v`
Expected: FAIL — `MatchError` because `Notes.delete_note/2` returns `{count, nil}`, not `:ok`.

- [ ] **Step 3: Fix the pattern match**

In `lib/engram_web/channels/sync_channel.ex`, change lines 80-92 from:

```elixir
  def handle_in("delete_note", %{"path" => path}, socket) do
    user = socket.assigns.current_user
    :ok = Notes.delete_note(user, path)

    broadcast_from!(socket, "note_changed", %{
      "event_type" => "delete",
      "path" => path,
      "kind" => "note",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    })

    {:reply, {:ok, %{"deleted" => true}}, socket}
  end
```

to:

```elixir
  def handle_in("delete_note", %{"path" => path}, socket) do
    user = socket.assigns.current_user
    Notes.delete_note(user, path)

    broadcast_from!(socket, "note_changed", %{
      "event_type" => "delete",
      "path" => path,
      "kind" => "note",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    })

    {:reply, {:ok, %{"deleted" => true}}, socket}
  end
```

- [ ] **Step 4: Run tests**

Run: `mix test test/engram_web/channels/sync_channel_test.exs -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/engram_web/channels/sync_channel.ex test/engram_web/channels/sync_channel_test.exs
git commit -m "fix: remove incorrect :ok pattern match on delete_note in SyncChannel

Notes.delete_note/2 returns {count, nil} from Repo.update_all,
not :ok. The match caused MatchError crashes on every channel delete."
```

---

### Task 4: Add note size validation to SyncChannel (H10)

**Files:**
- Modify: `lib/engram_web/channels/sync_channel.ex:51-72`
- Modify: `test/engram_web/channels/sync_channel_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/engram_web/channels/sync_channel_test.exs`:

```elixir
describe "push_note size limit" do
  test "rejects notes exceeding 10MB", %{socket: socket} do
    large_content = String.duplicate("x", 10_000_001)

    ref =
      push(socket, "push_note", %{
        "path" => "Test/huge.md",
        "content" => large_content,
        "mtime" => 1_709_234_567.0
      })

    assert_reply ref, :error, %{"reason" => "note_too_large"}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram_web/channels/sync_channel_test.exs --only "size limit" -v`
Expected: FAIL — note is accepted (no size check in channel).

- [ ] **Step 3: Add size check to push_note handler**

In `lib/engram_web/channels/sync_channel.ex`, change the `push_note` handler from:

```elixir
  @impl true
  def handle_in("push_note", params, socket) do
    user = socket.assigns.current_user

    case Notes.upsert_note(user, params) do
```

to:

```elixir
  # 10 MB — must match NotesController @max_note_bytes
  @max_note_bytes 10_000_000

  @impl true
  def handle_in("push_note", params, socket) do
    content = Map.get(params, "content", "")

    if byte_size(content) > @max_note_bytes do
      {:reply, {:error, %{"reason" => "note_too_large"}}, socket}
    else
      user = socket.assigns.current_user

      case Notes.upsert_note(user, params) do
```

And close the `if` block after the existing `end`:

```elixir
      end
    end
  end
```

- [ ] **Step 4: Run tests**

Run: `mix test test/engram_web/channels/sync_channel_test.exs -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/engram_web/channels/sync_channel.ex test/engram_web/channels/sync_channel_test.exs
git commit -m "fix: add 10MB note size validation to SyncChannel push_note

Matches the existing @max_note_bytes check in NotesController.
Previously the WebSocket channel had no size limit, allowing bypass."
```

---

### Task 5: Handle version_conflict in SyncChannel push_note (M29)

**Files:**
- Modify: `lib/engram_web/channels/sync_channel.ex:54-72`
- Modify: `test/engram_web/channels/sync_channel_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/engram_web/channels/sync_channel_test.exs`:

```elixir
describe "push_note version conflict" do
  test "returns conflict with server note when versions mismatch", %{socket: socket, user: user} do
    # Create initial note at version 1
    {:ok, _note} =
      Notes.upsert_note(user, %{
        "path" => "Test/conflict.md",
        "content" => "# V1",
        "mtime" => 1_709_234_567.0
      })

    # Push with stale version 0 — should conflict
    ref =
      push(socket, "push_note", %{
        "path" => "Test/conflict.md",
        "content" => "# Stale",
        "mtime" => 1_709_234_568.0,
        "version" => 0
      })

    assert_reply ref, :error, %{"reason" => "version_conflict", "server_note" => server_note}
    assert server_note["path"] == "Test/conflict.md"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram_web/channels/sync_channel_test.exs --only "version conflict" -v`
Expected: FAIL — `CaseClauseError` because `{:error, :version_conflict, server_note}` isn't matched.

- [ ] **Step 3: Add version_conflict clause**

In `lib/engram_web/channels/sync_channel.ex`, in the `push_note` handler's `case Notes.upsert_note(user, params) do` block, add after the `{:error, changeset}` clause:

```elixir
      {:error, :version_conflict, server_note} ->
        {:reply,
         {:error,
          %{
            "reason" => "version_conflict",
            "server_note" => serialize_note(server_note)
          }}, socket}
```

- [ ] **Step 4: Run tests**

Run: `mix test test/engram_web/channels/sync_channel_test.exs -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/engram_web/channels/sync_channel.ex test/engram_web/channels/sync_channel_test.exs
git commit -m "fix: handle version_conflict in SyncChannel push_note

Previously, a version conflict from Notes.upsert_note/2 caused a
CaseClauseError crash. Now returns {:error, version_conflict} with
the server's current note for client-side conflict resolution."
```

---

### Task 6: Fix suggest_folder crash in MCP handlers (H8)

**Files:**
- Modify: `lib/engram/mcp/handlers.ex:138-149`
- Modify: `test/engram_web/controllers/mcp_controller_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/engram_web/controllers/mcp_controller_test.exs` (or create a dedicated `test/engram/mcp/handlers_test.exs`):

```elixir
describe "suggest_folder" do
  test "returns markdown table when search returns results", %{conn: conn, user: user} do
    # Create notes in different folders
    for folder <- ["Daily", "Projects", "Projects"] do
      {:ok, _} =
        Notes.upsert_note(user, %{
          "path" => "#{folder}/note-#{System.unique_integer([:positive])}.md",
          "content" => "# Test note about coding",
          "mtime" => 1_709_234_567.0
        })
    end

    # Wait briefly for indexing if async
    Process.sleep(100)

    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "suggest_folder",
          "arguments" => %{"description" => "coding"}
        }
      })

    conn = post(conn, "/api/mcp", body)
    resp = json_response(conn, 200)

    # Should not crash — result should be a string
    assert is_binary(resp["result"]["content"] |> hd() |> Map.get("text"))
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram_web/controllers/mcp_controller_test.exs --only "suggest_folder" -v`
Expected: FAIL — `FunctionClauseError` when mapping over mixed list.

- [ ] **Step 3: Fix the list concatenation bug**

In `lib/engram/mcp/handlers.ex`, change lines 138-149 from:

```elixir
        if folder_counts == [] do
          "No folders found. The vault may be empty."
        else
          lines = ["| Rank | Folder | Notes |", "|------|--------|-------|"]

          lines =
            (lines ++
               Enum.with_index(folder_counts, 1))
            |> Enum.map(fn {{folder, count}, rank} ->
              folder_name = if folder == "", do: "(root)", else: folder
              "| #{rank} | #{folder_name} | #{count} |"
            end)

          Enum.join(lines, "\n")
        end
```

to:

```elixir
        if folder_counts == [] do
          "No folders found. The vault may be empty."
        else
          header = ["| Rank | Folder | Notes |", "|------|--------|-------|"]

          rows =
            folder_counts
            |> Enum.with_index(1)
            |> Enum.map(fn {{folder, count}, rank} ->
              folder_name = if folder == "", do: "(root)", else: folder
              "| #{rank} | #{folder_name} | #{count} |"
            end)

          Enum.join(header ++ rows, "\n")
        end
```

- [ ] **Step 4: Run tests**

Run: `mix test test/engram_web/controllers/mcp_controller_test.exs -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/engram/mcp/handlers.ex test/engram_web/controllers/mcp_controller_test.exs
git commit -m "fix: crash in suggest_folder MCP handler — mixed list concatenation

Header strings were concatenated with {tuple, index} pairs before
mapping. The map expected only tuples, causing FunctionClauseError.
Now builds header and rows separately before joining."
```

---

### Task 7: Add missing param fallback clauses (M30)

**Files:**
- Modify: `lib/engram_web/controllers/folders_controller.ex`
- Modify: `lib/engram_web/controllers/auth_controller.ex`
- Create: `test/engram_web/controllers/missing_params_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/engram_web/controllers/missing_params_test.exs`:

```elixir
defmodule EngramWeb.MissingParamsTest do
  use EngramWeb.ConnCase, async: true

  setup %{conn: conn} do
    {:ok, user} = Engram.Accounts.register(%{email: "params-test@example.com", password: "TestPass123!"})
    api_key = Engram.Accounts.create_api_key!(user, "test-key")

    Engram.Repo.insert!(
      %Engram.Billing.Subscription{
        user_id: user.id, status: "active", tier: "starter",
        stripe_customer_id: "cus_t", stripe_subscription_id: "sub_t"
      },
      skip_tenant_check: true
    )

    conn = put_req_header(conn, "authorization", "Bearer #{api_key.key}")
    {:ok, conn: conn}
  end

  test "POST /api/folders/rename without params returns 422", %{conn: conn} do
    conn = post(conn, "/api/folders/rename", %{})
    assert json_response(conn, 422)["error"]
  end

  test "POST /api/api-keys without name returns 422", %{conn: conn} do
    conn = post(conn, "/api/api-keys", %{})
    assert json_response(conn, 422)["error"]
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram_web/controllers/missing_params_test.exs -v`
Expected: FAIL — 500 FunctionClauseError.

- [ ] **Step 3: Add fallback clauses**

In `lib/engram_web/controllers/folders_controller.ex`, add after the existing `rename/2` function:

```elixir
  def rename(conn, _params) do
    conn |> put_status(422) |> json(%{error: "old_folder and new_folder are required"})
  end
```

In `lib/engram_web/controllers/auth_controller.ex`, add after the existing `create_api_key/2` function:

```elixir
  def create_api_key(conn, _params) do
    conn |> put_status(422) |> json(%{error: "name is required"})
  end
```

- [ ] **Step 4: Run tests**

Run: `mix test test/engram_web/controllers/missing_params_test.exs -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/engram_web/controllers/folders_controller.ex lib/engram_web/controllers/auth_controller.ex test/engram_web/controllers/missing_params_test.exs
git commit -m "fix: add fallback clauses for missing params in folders/auth controllers

Missing required params now return 422 with descriptive error
instead of crashing with 500 FunctionClauseError."
```
