# Self-Host Account Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a first-class Account tab at `/settings/account` for self-hosters (`authProvider === 'local'`): edit display name, change password, and soft-delete the account, with a last-admin guard.

**Architecture:** Backend grows three small surfaces on `Engram.Accounts` (`update_profile/2`, `active_admin_count/0`, `delete_self/2`) and two routes on the existing authed `/api` scope (`PATCH /api/me`, `DELETE /api/me`). The frontend adds a self-host-only `AccountPageLocal` that mounts focused section components and is selected at the lazy-import layer in `router.tsx` so Clerk imports never enter the local bundle path.

**Tech Stack:** Elixir/Phoenix 1.8, ExUnit, Ecto, React 18, TypeScript, TanStack Query, shadcn/ui (Radix), Vitest + RTL.

**Spec:** [`docs/superpowers/specs/2026-05-30-selfhost-account-settings-design.md`](../specs/2026-05-30-selfhost-account-settings-design.md)

**Working branch:** `feat/selfhost-account-settings` already exists on the workspace repo. Backend work goes on a sibling branch of the same name in `engram-app/engram`. Single PR per `feedback_single_pr_all_changes`.

---

## File Structure

### Backend (`backend/`)

| File | Op | Purpose |
|------|----|---------|
| `lib/engram/accounts.ex` | modify | Add `update_profile/2`, `active_admin_count/0`, `delete_self/2` |
| `lib/engram_web/controllers/users_controller.ex` | modify | Include `display_name` in `me/2`; add `update/2` (PATCH) and `delete/2` (DELETE self) |
| `lib/engram_web/router.ex` | modify | Wire `patch "/me"` and `delete "/me"` on the existing authed `/api` scope |
| `test/engram/accounts/profile_test.exs` | create | Unit tests for `update_profile`, `active_admin_count`, `delete_self` |
| `test/engram_web/controllers/users_controller_test.exs` | create or extend | HTTP tests for GET/PATCH/DELETE `/api/me` |

### Frontend (`backend/frontend/`)

| File | Op | Purpose |
|------|----|---------|
| `src/api/queries.ts` | modify | Extend `User` with `display_name`; add `useUpdateProfile`, `useDeleteSelf` mutations |
| `src/settings/sections.ts` | modify | Drop Clerk-only gate on `Account` |
| `src/settings/sections.test.ts` | modify | Cover the local-auth Account case |
| `src/router.tsx` | modify | Unconditional `account` route, lazy-branched by `config.authProvider`, index redirect → `'account'` |
| `src/settings/account-page-local.tsx` | create | Local Account page shell |
| `src/settings/account-page-local.test.tsx` | create | Page renders each section |
| `src/settings/account/profile-section-local.tsx` | create | `display_name` editor |
| `src/settings/account/profile-section-local.test.tsx` | create | RTL tests |
| `src/settings/account/email-readonly-section.tsx` | create | Read-only email + copy |
| `src/settings/account/email-readonly-section.test.tsx` | create | RTL tests |
| `src/settings/account/password-section-local.tsx` | create | Old/new/confirm password form |
| `src/settings/account/password-section-local.test.tsx` | create | RTL tests |
| `src/settings/account/danger-zone-section-local.tsx` | create | Password-reverify delete dialog |
| `src/settings/account/danger-zone-section-local.test.tsx` | create | RTL tests |

### Workspace (`engram-workspace`)

| File | Op | Purpose |
|------|----|---------|
| `docs/superpowers/plans/2026-05-30-selfhost-account-settings.md` | this file | The plan itself |

---

## Conventions

- Run all backend commands from `backend/`. Run all frontend commands from `backend/frontend/`. Workspace-level files commit in `engram-workspace`.
- Commit after every task on the feature branch.
- Test names mirror the existing project style: backend `test/engram/...` matching `lib/engram/...`; frontend co-located `*.test.tsx`.
- Conventional commits.

---

## Task 1: Backend — `Engram.Accounts.update_profile/2`

**Files:**
- Modify: `backend/lib/engram/accounts.ex`
- Create: `backend/test/engram/accounts/profile_test.exs`

- [ ] **Step 1: Write the failing test**

Create `backend/test/engram/accounts/profile_test.exs`:

```elixir
defmodule Engram.Accounts.ProfileTest do
  use Engram.DataCase, async: true

  alias Engram.Accounts

  describe "update_profile/2" do
    test "updates display_name" do
      {:ok, user} = Accounts.create_user_with_password("alice@example.com", "password123")

      assert {:ok, updated} = Accounts.update_profile(user, %{display_name: "Alice"})
      assert updated.display_name == "Alice"
    end

    test "trims whitespace and clears with empty string" do
      {:ok, user} = Accounts.create_user_with_password("bob@example.com", "password123")

      {:ok, named} = Accounts.update_profile(user, %{display_name: "  Bob  "})
      assert named.display_name == "Bob"

      {:ok, cleared} = Accounts.update_profile(named, %{display_name: ""})
      assert is_nil(cleared.display_name)
    end

    test "rejects display_name longer than 80 chars" do
      {:ok, user} = Accounts.create_user_with_password("cara@example.com", "password123")
      too_long = String.duplicate("a", 81)

      assert {:error, %Ecto.Changeset{} = cs} =
               Accounts.update_profile(user, %{display_name: too_long})

      assert %{display_name: ["should be at most 80 character(s)"]} = errors_on(cs)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd backend && mix test test/engram/accounts/profile_test.exs
```

Expected: FAIL — `function Engram.Accounts.update_profile/2 is undefined`.

- [ ] **Step 3: Implement `update_profile/2`**

In `backend/lib/engram/accounts.ex`, after `update_password/2`, add:

```elixir
@max_display_name_chars 80

@doc """
Updates the editable profile fields on a user. Currently just `display_name`.
Empty/whitespace string clears the field (stored as nil).
"""
def update_profile(%User{} = user, attrs) do
  user
  |> profile_changeset(attrs)
  |> Repo.update(skip_tenant_check: true)
end

defp profile_changeset(user, attrs) do
  user
  |> Ecto.Changeset.cast(attrs, [:display_name])
  |> Ecto.Changeset.update_change(:display_name, fn
    nil -> nil
    val ->
      case String.trim(val) do
        "" -> nil
        trimmed -> trimmed
      end
  end)
  |> Ecto.Changeset.validate_length(:display_name, max: @max_display_name_chars, count: :codepoints)
end
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd backend && mix test test/engram/accounts/profile_test.exs
```

Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
cd backend
git checkout -b feat/selfhost-account-settings
git add lib/engram/accounts.ex test/engram/accounts/profile_test.exs
git commit -m "feat(accounts): add update_profile/2 for display_name"
```

---

## Task 2: Backend — `Engram.Accounts.active_admin_count/0`

**Files:**
- Modify: `backend/lib/engram/accounts.ex`
- Modify: `backend/test/engram/accounts/profile_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `backend/test/engram/accounts/profile_test.exs`:

```elixir
  describe "active_admin_count/0" do
    test "counts only admins that are not deleted or suspended" do
      {:ok, _bootstrap_admin} =
        Accounts.create_user_with_password("admin1@example.com", "password123")

      # Subsequent users default to member.
      {:ok, _member} = Accounts.create_user_with_password("member@example.com", "password123")

      assert Accounts.active_admin_count() == 1
    end

    test "ignores soft-deleted admins" do
      {:ok, admin} = Accounts.create_user_with_password("admin2@example.com", "password123")

      admin
      |> Ecto.Changeset.change(%{deleted_at: DateTime.utc_now()})
      |> Engram.Repo.update!(skip_tenant_check: true)

      assert Accounts.active_admin_count() == 0
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd backend && mix test test/engram/accounts/profile_test.exs
```

Expected: FAIL — `function Engram.Accounts.active_admin_count/0 is undefined`.

- [ ] **Step 3: Implement `active_admin_count/0`**

In `backend/lib/engram/accounts.ex`, add near the other user query helpers (right after `update_profile`):

```elixir
@doc """
Number of non-deleted, non-suspended users with admin role. Used to block
the last admin from self-deleting via DELETE /api/me.
"""
def active_admin_count do
  from(u in User,
    where: u.role == "admin" and is_nil(u.deleted_at) and is_nil(u.suspended_at),
    select: count(u.id)
  )
  |> Repo.one(skip_tenant_check: true)
end
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd backend && mix test test/engram/accounts/profile_test.exs
```

Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
cd backend
git add lib/engram/accounts.ex test/engram/accounts/profile_test.exs
git commit -m "feat(accounts): add active_admin_count/0"
```

---

## Task 3: Backend — `Engram.Accounts.delete_self/2`

**Files:**
- Modify: `backend/lib/engram/accounts.ex`
- Modify: `backend/test/engram/accounts/profile_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `backend/test/engram/accounts/profile_test.exs`:

```elixir
  describe "delete_self/2" do
    test "soft-deletes member, revokes refresh tokens, deletes api keys" do
      {:ok, _admin} = Accounts.create_user_with_password("keep-admin@example.com", "password123")
      {:ok, user} = Accounts.create_user_with_password("victim@example.com", "password123")

      {:ok, _raw, _record} = Accounts.create_refresh_token(user)
      {:ok, _key, _record} = Accounts.create_api_key(user, "ci")

      assert :ok = Accounts.delete_self(user, "password123")

      reloaded = Engram.Repo.get!(Engram.Accounts.User, user.id, skip_tenant_check: true)
      refute is_nil(reloaded.deleted_at)

      tokens =
        Engram.Repo.all(
          from(rt in Engram.Auth.RefreshToken,
            where: rt.user_id == ^user.id and is_nil(rt.revoked_at)
          ),
          skip_tenant_check: true
        )

      assert tokens == []

      assert Accounts.list_api_keys(reloaded) == []
    end

    test "returns :invalid_password when password is wrong" do
      {:ok, _admin} = Accounts.create_user_with_password("admin3@example.com", "password123")
      {:ok, user} = Accounts.create_user_with_password("wrong@example.com", "password123")

      assert {:error, :invalid_password} = Accounts.delete_self(user, "nope")

      reloaded = Engram.Repo.get!(Engram.Accounts.User, user.id, skip_tenant_check: true)
      assert is_nil(reloaded.deleted_at)
    end

    test "returns :last_admin when admin is the only active admin" do
      {:ok, admin} = Accounts.create_user_with_password("solo-admin@example.com", "password123")

      assert {:error, :last_admin} = Accounts.delete_self(admin, "password123")

      reloaded = Engram.Repo.get!(Engram.Accounts.User, admin.id, skip_tenant_check: true)
      assert is_nil(reloaded.deleted_at)
    end

    test "allows admin delete when another admin remains" do
      {:ok, admin_a} = Accounts.create_user_with_password("admin-a@example.com", "password123")

      {:ok, admin_b} =
        Accounts.create_user_with_password("admin-b@example.com", "password123")
      # Second user defaults to member; promote manually for this test.
      admin_b =
        admin_b
        |> Ecto.Changeset.change(%{role: "admin"})
        |> Engram.Repo.update!(skip_tenant_check: true)

      assert :ok = Accounts.delete_self(admin_a, "password123")

      reloaded = Engram.Repo.get!(Engram.Accounts.User, admin_a.id, skip_tenant_check: true)
      refute is_nil(reloaded.deleted_at)
      _ = admin_b
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd backend && mix test test/engram/accounts/profile_test.exs
```

Expected: FAIL — `function Engram.Accounts.delete_self/2 is undefined`.

- [ ] **Step 3: Implement `delete_self/2`**

In `backend/lib/engram/accounts.ex`, add near the other user-mutation helpers:

```elixir
@doc """
Self-delete flow for local-auth users:
  1. verify password
  2. block if this is the last active admin
  3. set deleted_at, revoke all refresh tokens, hard-delete api keys

The existing login chokepoint in `verify_password/2` blocks re-auth as
soon as `deleted_at` is set, so no token cleanup is required beyond
revoke_all_user_tokens/1.
"""
def delete_self(%User{} = user, password) when is_binary(password) do
  with {:ok, _} <- verify_password(user.email, password),
       :ok <- guard_last_admin(user) do
    Repo.transaction(
      fn ->
        now = DateTime.utc_now()

        user
        |> Ecto.Changeset.change(%{deleted_at: now})
        |> Repo.update!(skip_tenant_check: true)

        revoke_all_user_tokens(user)

        from(k in Engram.Accounts.ApiKey, where: k.user_id == ^user.id)
        |> Repo.delete_all(skip_tenant_check: true)

        :ok
      end,
      skip_tenant_check: true
    )
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  else
    {:error, :invalid_credentials} -> {:error, :invalid_password}
    {:error, :last_admin} -> {:error, :last_admin}
    {:error, other} -> {:error, other}
  end
end

defp guard_last_admin(%User{role: "admin"} = _user) do
  if active_admin_count() <= 1, do: {:error, :last_admin}, else: :ok
end

defp guard_last_admin(_user), do: :ok
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd backend && mix test test/engram/accounts/profile_test.exs
```

Expected: PASS (9 tests).

- [ ] **Step 5: Commit**

```bash
cd backend
git add lib/engram/accounts.ex test/engram/accounts/profile_test.exs
git commit -m "feat(accounts): add delete_self/2 (soft-delete + last-admin guard)"
```

---

## Task 4: Backend — `UsersController` GET/PATCH/DELETE `/api/me`

**Files:**
- Modify: `backend/lib/engram_web/controllers/users_controller.ex`
- Modify: `backend/lib/engram_web/router.ex`
- Create: `backend/test/engram_web/controllers/users_controller_test.exs`

- [ ] **Step 1: Write failing controller tests**

Create `backend/test/engram_web/controllers/users_controller_test.exs`:

```elixir
defmodule EngramWeb.UsersControllerTest do
  use EngramWeb.ConnCase, async: true

  alias Engram.Accounts

  defp auth_conn(user) do
    {:ok, jwt, _} = Accounts.generate_jwt(user)
    build_conn() |> put_req_header("authorization", "Bearer " <> jwt)
  end

  setup do
    # Bootstrap admin so members can exist without inheriting admin role.
    {:ok, _bootstrap} =
      Accounts.create_user_with_password("bootstrap-admin@example.com", "password123")

    {:ok, user} = Accounts.create_user_with_password("user@example.com", "password123")

    {:ok, user: user}
  end

  describe "GET /api/me" do
    test "returns id, email, role, display_name", %{conn: _conn, user: user} do
      conn = auth_conn(user) |> get("/api/me")
      body = json_response(conn, 200)
      assert body["user"]["email"] == "user@example.com"
      assert body["user"]["role"] == "member"
      assert Map.has_key?(body["user"], "display_name")
    end
  end

  describe "PATCH /api/me" do
    test "updates display_name", %{user: user} do
      conn =
        auth_conn(user)
        |> put_req_header("content-type", "application/json")
        |> patch("/api/me", Jason.encode!(%{display_name: "Pat"}))

      body = json_response(conn, 200)
      assert body["user"]["display_name"] == "Pat"
    end

    test "422 on too-long display_name", %{user: user} do
      conn =
        auth_conn(user)
        |> put_req_header("content-type", "application/json")
        |> patch("/api/me", Jason.encode!(%{display_name: String.duplicate("x", 81)}))

      assert %{"error" => "validation_failed"} = json_response(conn, 422)
    end

    test "401 without bearer", %{user: _user} do
      conn = build_conn() |> patch("/api/me", %{display_name: "x"})
      assert response(conn, 401)
    end
  end

  describe "DELETE /api/me" do
    test "204 with correct password, soft-deletes", %{user: user} do
      conn =
        auth_conn(user)
        |> put_req_header("content-type", "application/json")
        |> delete("/api/me", Jason.encode!(%{password: "password123"}))

      assert response(conn, 204)

      reloaded = Engram.Repo.get!(Engram.Accounts.User, user.id, skip_tenant_check: true)
      refute is_nil(reloaded.deleted_at)
    end

    test "403 on wrong password", %{user: user} do
      conn =
        auth_conn(user)
        |> put_req_header("content-type", "application/json")
        |> delete("/api/me", Jason.encode!(%{password: "wrong"}))

      assert %{"error" => "invalid_password"} = json_response(conn, 403)
    end

    test "409 last_admin for the only admin" do
      # Delete the bootstrap admin's safety net by making them the only admin
      # AND deleting the user fixture so only one admin remains.
      admin = Accounts.find_by_normalized_email("bootstrap-admin@example.com")
      assert admin
      assert admin.role == "admin"

      # No second admin exists.
      conn =
        auth_conn(admin)
        |> put_req_header("content-type", "application/json")
        |> delete("/api/me", Jason.encode!(%{password: "password123"}))

      assert %{"error" => "last_admin"} = json_response(conn, 409)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd backend && mix test test/engram_web/controllers/users_controller_test.exs
```

Expected: FAIL — routes return 404 or function clauses missing.

- [ ] **Step 3: Add the routes**

In `backend/lib/engram_web/router.ex`, inside `scope "/api"` at line ~143 (the authed pipeline that already holds `get "/me"`), add:

```elixir
    get "/me", UsersController, :me
    patch "/me", UsersController, :update
    delete "/me", UsersController, :delete
```

- [ ] **Step 4: Implement the controller actions**

Replace `backend/lib/engram_web/controllers/users_controller.ex` with:

```elixir
defmodule EngramWeb.UsersController do
  use EngramWeb, :controller

  alias Engram.Accounts

  def me(conn, _params) do
    user = conn.assigns.current_user

    json(conn, %{
      user: %{
        id: user.id,
        email: user.email,
        role: user.role,
        display_name: user.display_name
      }
    })
  end

  def update(conn, params) do
    user = conn.assigns.current_user
    attrs = Map.take(params, ["display_name"])

    case Accounts.update_profile(user, attrs) do
      {:ok, updated} ->
        json(conn, %{
          user: %{
            id: updated.id,
            email: updated.email,
            role: updated.role,
            display_name: updated.display_name
          }
        })

      {:error, %Ecto.Changeset{} = cs} ->
        details = Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
          Enum.reduce(opts, msg, fn {k, v}, acc ->
            String.replace(acc, "%{#{k}}", to_string(v))
          end)
        end)

        conn
        |> put_status(422)
        |> json(%{error: "validation_failed", details: details})
    end
  end

  def delete(conn, %{"password" => password}) when is_binary(password) do
    user = conn.assigns.current_user

    case Accounts.delete_self(user, password) do
      :ok ->
        conn |> put_status(204) |> send_resp(204, "")

      {:error, :invalid_password} ->
        conn |> put_status(403) |> json(%{error: "invalid_password"})

      {:error, :last_admin} ->
        conn |> put_status(409) |> json(%{error: "last_admin"})

      {:error, _other} ->
        conn |> put_status(422) |> json(%{error: "delete_failed"})
    end
  end

  def delete(conn, _params) do
    conn |> put_status(400) |> json(%{error: "password_required"})
  end
end
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd backend && mix test test/engram_web/controllers/users_controller_test.exs test/engram/accounts/profile_test.exs
```

Expected: PASS (all tests).

- [ ] **Step 6: Run full backend suite to guard against regressions**

```bash
cd backend && mix test
```

Expected: full suite green.

- [ ] **Step 7: Commit**

```bash
cd backend
git add lib/engram_web/controllers/users_controller.ex lib/engram_web/router.ex \
        test/engram_web/controllers/users_controller_test.exs
git commit -m "feat(api): PATCH/DELETE /api/me for self-host account edit + delete"
```

---

## Task 5: Frontend — Extend `User` type + add mutation hooks

**Files:**
- Modify: `backend/frontend/src/api/queries.ts`

- [ ] **Step 1: Extend the `User` type**

In `backend/frontend/src/api/queries.ts`, update:

```typescript
export interface User {
  id: number
  email: string
  role: 'admin' | 'member'
  display_name: string | null
}
```

- [ ] **Step 2: Add `useUpdateProfile`**

At the end of the file (or near the other mutations), add:

```typescript
export function useUpdateProfile() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (body: { display_name: string | null }) =>
      api.patch<{ user: User }>('/me', body),
    onSuccess: (data) => {
      qc.setQueryData(['me'], data)
    },
  })
}
```

- [ ] **Step 3: Add `useDeleteSelf`**

Append:

```typescript
export function useDeleteSelf() {
  return useMutation<void, Error, { password: string }>({
    mutationFn: async ({ password }) => {
      await api.del<void>(`/me?password=${encodeURIComponent(password)}`)
    },
  })
}
```

**Note:** `api.del<T>` does not accept a body — pass `password` as a query string. The backend reads from `conn.params`, which Phoenix populates from both query and body, so this works without changing the controller.

Update the controller test from Task 4 to send password as query string instead:

```elixir
# In test/engram_web/controllers/users_controller_test.exs, replace the
# `delete("/api/me", Jason.encode!(%{password: "password123"}))` calls with:
delete("/api/me?password=password123")
```

Re-run controller test to confirm:

```bash
cd backend && mix test test/engram_web/controllers/users_controller_test.exs
```

Expected: PASS.

- [ ] **Step 4: Type-check**

```bash
cd backend/frontend && bun run build
```

Expected: build succeeds (tsc + Vite).

- [ ] **Step 5: Commit**

```bash
cd backend
git add frontend/src/api/queries.ts test/engram_web/controllers/users_controller_test.exs
git commit -m "feat(frontend): useUpdateProfile + useDeleteSelf hooks"
```

---

## Task 6: Frontend — Update settings sidebar to include Account for local auth

**Files:**
- Modify: `backend/frontend/src/settings/sections.ts`
- Modify: `backend/frontend/src/settings/sections.test.ts`

- [ ] **Step 1: Update the failing test first**

In `backend/frontend/src/settings/sections.test.ts`, find or add:

```typescript
import { describe, expect, it } from 'vitest'
import { buildSettingsSections } from './sections'

describe('buildSettingsSections', () => {
  it('includes Account first for local auth', () => {
    const sections = buildSettingsSections('local', false, false)
    expect(sections[0]).toEqual({ to: 'account', label: 'Account' })
    expect(sections.map((s) => s.to)).toContain('vaults')
    expect(sections.map((s) => s.to)).toContain('api-keys')
  })

  it('includes Account first for clerk', () => {
    const sections = buildSettingsSections('clerk', true, false)
    expect(sections[0]).toEqual({ to: 'account', label: 'Account' })
    expect(sections.map((s) => s.to)).toContain('billing')
  })

  it('appends Administration for local admins', () => {
    const sections = buildSettingsSections('local', false, true)
    expect(sections.map((s) => s.to)).toContain('admin')
  })
})
```

- [ ] **Step 2: Run test to verify failure**

```bash
cd backend/frontend && bun test sections.test.ts
```

Expected: FAIL — local sections do not start with Account.

- [ ] **Step 3: Update `buildSettingsSections`**

Replace the contents of `backend/frontend/src/settings/sections.ts` with:

```typescript
import type { EngramConfig } from '../config'

export interface SettingsSection {
  to: string
  label: string
}

export function buildSettingsSections(
  authProvider: EngramConfig['authProvider'],
  billingEnabled: boolean,
  isAdmin = false,
): SettingsSection[] {
  const sections: SettingsSection[] = [
    { to: 'account', label: 'Account' },
    { to: 'vaults', label: 'Vaults' },
    { to: 'api-keys', label: 'API Keys' },
  ]

  if (billingEnabled) {
    sections.push({ to: 'billing', label: 'Billing' })
  }

  if (authProvider === 'local' && isAdmin) {
    sections.push({ to: 'admin', label: 'Administration' })
  }

  return sections
}
```

- [ ] **Step 4: Run test to verify pass**

```bash
cd backend/frontend && bun test sections.test.ts
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd backend
git add frontend/src/settings/sections.ts frontend/src/settings/sections.test.ts
git commit -m "feat(settings): include Account tab for local auth"
```

---

## Task 7: Frontend — `ProfileSectionLocal`

**Files:**
- Create: `backend/frontend/src/settings/account/profile-section-local.tsx`
- Create: `backend/frontend/src/settings/account/profile-section-local.test.tsx`

- [ ] **Step 1: Write the failing test**

Create `backend/frontend/src/settings/account/profile-section-local.test.tsx`:

```tsx
import { describe, expect, it, vi } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const updateMutate = vi.fn().mockResolvedValue({ user: { display_name: 'Sam' } })
const meData = { user: { id: 1, email: 'me@example.com', role: 'member', display_name: 'Old' } }

vi.mock('../../api/queries', () => ({
  useMe: () => ({ data: meData }),
  useUpdateProfile: () => ({ mutateAsync: updateMutate, isPending: false }),
}))

import { ProfileSectionLocal } from './profile-section-local'

function wrap(ui: React.ReactNode) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(<QueryClientProvider client={qc}>{ui}</QueryClientProvider>)
}

describe('ProfileSectionLocal', () => {
  it('shows current display_name and submits new value', async () => {
    wrap(<ProfileSectionLocal />)
    const input = screen.getByLabelText(/display name/i) as HTMLInputElement
    expect(input.value).toBe('Old')

    fireEvent.change(input, { target: { value: 'Sam' } })
    fireEvent.click(screen.getByRole('button', { name: /save/i }))

    await waitFor(() =>
      expect(updateMutate).toHaveBeenCalledWith({ display_name: 'Sam' }),
    )
  })
})
```

- [ ] **Step 2: Run test to verify failure**

```bash
cd backend/frontend && bun test profile-section-local.test.tsx
```

Expected: FAIL — `Failed to resolve import "./profile-section-local"`.

- [ ] **Step 3: Implement `ProfileSectionLocal`**

Create `backend/frontend/src/settings/account/profile-section-local.tsx`:

```tsx
import { useState, useEffect } from 'react'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { useMe, useUpdateProfile } from '../../api/queries'
import { SettingsSectionCard } from './section-card'

export function ProfileSectionLocal() {
  const { data } = useMe()
  const update = useUpdateProfile()
  const current = data?.user.display_name ?? ''
  const [value, setValue] = useState(current)

  useEffect(() => {
    setValue(current)
  }, [current])

  const dirty = value.trim() !== (current ?? '').trim()

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault()
    try {
      await update.mutateAsync({ display_name: value.trim() === '' ? null : value.trim() })
      toast.success('Profile updated')
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Could not update profile')
    }
  }

  return (
    <SettingsSectionCard title="Profile" description="How your name appears in the app.">
      <form onSubmit={onSubmit} className="space-y-3">
        <fieldset className="space-y-1.5">
          <Label htmlFor="display-name">Display name</Label>
          <Input
            id="display-name"
            value={value}
            maxLength={80}
            onChange={(e) => setValue(e.target.value)}
            placeholder="Leave blank to use your email"
          />
        </fieldset>
        <Button type="submit" size="sm" disabled={!dirty || update.isPending}>
          {update.isPending ? 'Saving…' : 'Save'}
        </Button>
      </form>
    </SettingsSectionCard>
  )
}
```

- [ ] **Step 4: Run test to verify pass**

```bash
cd backend/frontend && bun test profile-section-local.test.tsx
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd backend
git add frontend/src/settings/account/profile-section-local.tsx \
        frontend/src/settings/account/profile-section-local.test.tsx
git commit -m "feat(settings): ProfileSectionLocal display_name editor"
```

---

## Task 8: Frontend — `EmailReadonlySection`

**Files:**
- Create: `backend/frontend/src/settings/account/email-readonly-section.tsx`
- Create: `backend/frontend/src/settings/account/email-readonly-section.test.tsx`

- [ ] **Step 1: Write the failing test**

Create `backend/frontend/src/settings/account/email-readonly-section.test.tsx`:

```tsx
import { describe, expect, it, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'

const meData = { user: { id: 1, email: 'me@example.com', role: 'member', display_name: null } }
vi.mock('../../api/queries', () => ({ useMe: () => ({ data: meData }) }))

import { EmailReadonlySection } from './email-readonly-section'

describe('EmailReadonlySection', () => {
  it('renders the user email', () => {
    render(<EmailReadonlySection />)
    expect(screen.getByText('me@example.com')).toBeInTheDocument()
  })

  it('mentions contacting an admin', () => {
    render(<EmailReadonlySection />)
    expect(screen.getByText(/contact your admin/i)).toBeInTheDocument()
  })

  it('copy button writes to clipboard', async () => {
    const writeText = vi.fn().mockResolvedValue(undefined)
    Object.assign(navigator, { clipboard: { writeText } })

    render(<EmailReadonlySection />)
    fireEvent.click(screen.getByRole('button', { name: /copy email/i }))

    expect(writeText).toHaveBeenCalledWith('me@example.com')
  })
})
```

- [ ] **Step 2: Run test to verify failure**

```bash
cd backend/frontend && bun test email-readonly-section.test.tsx
```

Expected: FAIL — import error.

- [ ] **Step 3: Implement the section**

Create `backend/frontend/src/settings/account/email-readonly-section.tsx`:

```tsx
import { Copy } from 'lucide-react'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { useMe } from '../../api/queries'
import { SettingsSectionCard } from './section-card'

export function EmailReadonlySection() {
  const { data } = useMe()
  const email = data?.user.email ?? ''

  async function copy() {
    try {
      await navigator.clipboard.writeText(email)
      toast.success('Email copied')
    } catch {
      toast.error('Could not copy')
    }
  }

  return (
    <SettingsSectionCard
      title="Email"
      description="To change your email, contact your admin."
    >
      <div className="flex items-center justify-between gap-3 rounded-md border border-border bg-muted/40 px-3 py-2">
        <span className="truncate font-mono text-sm">{email}</span>
        <Button
          type="button"
          variant="ghost"
          size="sm"
          aria-label="Copy email"
          onClick={copy}
          className="gap-1"
        >
          <Copy className="size-4" /> Copy
        </Button>
      </div>
    </SettingsSectionCard>
  )
}
```

- [ ] **Step 4: Run test to verify pass**

```bash
cd backend/frontend && bun test email-readonly-section.test.tsx
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd backend
git add frontend/src/settings/account/email-readonly-section.tsx \
        frontend/src/settings/account/email-readonly-section.test.tsx
git commit -m "feat(settings): EmailReadonlySection for self-host"
```

---

## Task 9: Frontend — `PasswordSectionLocal`

**Files:**
- Create: `backend/frontend/src/settings/account/password-section-local.tsx`
- Create: `backend/frontend/src/settings/account/password-section-local.test.tsx`

- [ ] **Step 1: Write the failing test**

Create `backend/frontend/src/settings/account/password-section-local.test.tsx`:

```tsx
import { describe, expect, it, vi } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'

const logout = vi.fn().mockResolvedValue(undefined)
vi.mock('../../auth/use-auth-adapter', () => ({
  useAuthAdapter: () => ({ logout }),
}))

const apiPost = vi.fn().mockResolvedValue({ ok: true })
vi.mock('../../api/client', () => ({
  api: { post: apiPost },
}))

const navigate = vi.fn()
vi.mock('react-router', () => ({ useNavigate: () => navigate }))

import { PasswordSectionLocal } from './password-section-local'

describe('PasswordSectionLocal', () => {
  it('blocks submit when new + confirm mismatch', async () => {
    render(<PasswordSectionLocal />)
    fireEvent.change(screen.getByLabelText(/current password/i), { target: { value: 'old' } })
    fireEvent.change(screen.getByLabelText(/^new password$/i), { target: { value: 'newpass12' } })
    fireEvent.change(screen.getByLabelText(/confirm new password/i), {
      target: { value: 'different' },
    })
    fireEvent.click(screen.getByRole('button', { name: /change password/i }))

    expect(await screen.findByText(/passwords do not match/i)).toBeInTheDocument()
    expect(apiPost).not.toHaveBeenCalled()
  })

  it('submits, logs out, and redirects on success', async () => {
    render(<PasswordSectionLocal />)
    fireEvent.change(screen.getByLabelText(/current password/i), { target: { value: 'oldpass12' } })
    fireEvent.change(screen.getByLabelText(/^new password$/i), { target: { value: 'newpass12' } })
    fireEvent.change(screen.getByLabelText(/confirm new password/i), {
      target: { value: 'newpass12' },
    })
    fireEvent.click(screen.getByRole('button', { name: /change password/i }))

    await waitFor(() =>
      expect(apiPost).toHaveBeenCalledWith('/auth/password/change', {
        old_password: 'oldpass12',
        new_password: 'newpass12',
      }),
    )
    await waitFor(() => expect(logout).toHaveBeenCalled())
    await waitFor(() => expect(navigate).toHaveBeenCalledWith('/sign-in'))
  })
})
```

- [ ] **Step 2: Run test to verify failure**

```bash
cd backend/frontend && bun test password-section-local.test.tsx
```

Expected: FAIL — import error.

- [ ] **Step 3: Implement the section**

Create `backend/frontend/src/settings/account/password-section-local.tsx`:

```tsx
import { useState } from 'react'
import { useNavigate } from 'react-router'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { api } from '../../api/client'
import { useAuthAdapter } from '../../auth/use-auth-adapter'
import { ROUTES } from '../../routes'
import { SettingsSectionCard } from './section-card'

export function PasswordSectionLocal() {
  const { logout } = useAuthAdapter()
  const navigate = useNavigate()
  const [oldPw, setOldPw] = useState('')
  const [newPw, setNewPw] = useState('')
  const [confirmPw, setConfirmPw] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [submitting, setSubmitting] = useState(false)

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault()
    setError(null)

    if (newPw !== confirmPw) {
      setError('Passwords do not match')
      return
    }
    if (newPw.length < 8) {
      setError('New password must be at least 8 characters')
      return
    }

    setSubmitting(true)
    try {
      await api.post('/auth/password/change', { old_password: oldPw, new_password: newPw })
      toast.success('Password changed — please sign in again')
      await logout()
      navigate(ROUTES.SIGN_IN)
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Password change failed'
      setError(msg)
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <SettingsSectionCard
      title="Password"
      description="Changing your password signs you out on all devices."
    >
      <form onSubmit={onSubmit} className="space-y-3">
        <fieldset className="space-y-1.5">
          <Label htmlFor="old-password">Current password</Label>
          <Input
            id="old-password"
            type="password"
            autoComplete="current-password"
            value={oldPw}
            onChange={(e) => setOldPw(e.target.value)}
            required
          />
        </fieldset>
        <fieldset className="space-y-1.5">
          <Label htmlFor="new-password">New password</Label>
          <Input
            id="new-password"
            type="password"
            autoComplete="new-password"
            value={newPw}
            onChange={(e) => setNewPw(e.target.value)}
            required
          />
        </fieldset>
        <fieldset className="space-y-1.5">
          <Label htmlFor="confirm-password">Confirm new password</Label>
          <Input
            id="confirm-password"
            type="password"
            autoComplete="new-password"
            value={confirmPw}
            onChange={(e) => setConfirmPw(e.target.value)}
            required
          />
        </fieldset>
        {error && <p className="text-sm text-destructive">{error}</p>}
        <Button type="submit" size="sm" disabled={submitting}>
          {submitting ? 'Changing…' : 'Change password'}
        </Button>
      </form>
    </SettingsSectionCard>
  )
}
```

- [ ] **Step 4: Run test to verify pass**

```bash
cd backend/frontend && bun test password-section-local.test.tsx
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd backend
git add frontend/src/settings/account/password-section-local.tsx \
        frontend/src/settings/account/password-section-local.test.tsx
git commit -m "feat(settings): PasswordSectionLocal change form"
```

---

## Task 10: Frontend — `DangerZoneSectionLocal`

**Files:**
- Create: `backend/frontend/src/settings/account/danger-zone-section-local.tsx`
- Create: `backend/frontend/src/settings/account/danger-zone-section-local.test.tsx`

- [ ] **Step 1: Write the failing test**

Create `backend/frontend/src/settings/account/danger-zone-section-local.test.tsx`:

```tsx
import { describe, expect, it, vi } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'

const logout = vi.fn().mockResolvedValue(undefined)
vi.mock('../../auth/use-auth-adapter', () => ({
  useAuthAdapter: () => ({ logout }),
}))

const navigate = vi.fn()
vi.mock('react-router', () => ({ useNavigate: () => navigate }))

const deleteMutate = vi.fn()
vi.mock('../../api/queries', () => ({
  useDeleteSelf: () => ({ mutateAsync: deleteMutate, isPending: false }),
}))

import { DangerZoneSectionLocal } from './danger-zone-section-local'

describe('DangerZoneSectionLocal', () => {
  it('requires password and submits delete', async () => {
    deleteMutate.mockResolvedValueOnce(undefined)
    render(<DangerZoneSectionLocal />)

    fireEvent.click(screen.getByRole('button', { name: /delete account/i }))
    fireEvent.change(await screen.findByLabelText(/password/i), {
      target: { value: 'password123' },
    })
    fireEvent.click(screen.getByLabelText(/i understand/i))
    fireEvent.click(screen.getByRole('button', { name: /^delete$/i }))

    await waitFor(() => expect(deleteMutate).toHaveBeenCalledWith({ password: 'password123' }))
    await waitFor(() => expect(logout).toHaveBeenCalled())
    await waitFor(() => expect(navigate).toHaveBeenCalledWith('/sign-in'))
  })

  it('shows last-admin error and does not log out', async () => {
    deleteMutate.mockRejectedValueOnce(new Error('last_admin'))
    render(<DangerZoneSectionLocal />)

    fireEvent.click(screen.getByRole('button', { name: /delete account/i }))
    fireEvent.change(await screen.findByLabelText(/password/i), {
      target: { value: 'password123' },
    })
    fireEvent.click(screen.getByLabelText(/i understand/i))
    fireEvent.click(screen.getByRole('button', { name: /^delete$/i }))

    expect(await screen.findByText(/only admin/i)).toBeInTheDocument()
    expect(logout).not.toHaveBeenCalled()
  })
})
```

- [ ] **Step 2: Run test to verify failure**

```bash
cd backend/frontend && bun test danger-zone-section-local.test.tsx
```

Expected: FAIL — import error.

- [ ] **Step 3: Implement the section**

Create `backend/frontend/src/settings/account/danger-zone-section-local.tsx`:

```tsx
import { useState } from 'react'
import { useNavigate } from 'react-router'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Checkbox } from '@/components/ui/checkbox'
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from '@/components/ui/alert-dialog'
import { useDeleteSelf } from '../../api/queries'
import { useAuthAdapter } from '../../auth/use-auth-adapter'
import { ROUTES } from '../../routes'
import { SettingsSectionCard } from './section-card'

export function DangerZoneSectionLocal() {
  const { logout } = useAuthAdapter()
  const navigate = useNavigate()
  const deleter = useDeleteSelf()
  const [password, setPassword] = useState('')
  const [confirmed, setConfirmed] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [open, setOpen] = useState(false)

  async function onDelete() {
    setError(null)
    try {
      await deleter.mutateAsync({ password })
      toast.success('Account deleted')
      await logout()
      navigate(ROUTES.SIGN_IN)
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Delete failed'
      if (msg.includes('last_admin')) {
        setError(
          "You're the only admin on this instance. Promote another user to admin first, then try again.",
        )
      } else if (msg.includes('invalid_password')) {
        setError('Incorrect password.')
      } else {
        setError(msg)
      }
    }
  }

  function reset() {
    setPassword('')
    setConfirmed(false)
    setError(null)
  }

  return (
    <SettingsSectionCard
      title="Danger zone"
      description="Permanent actions. Deleting your account signs you out and blocks future sign-ins to this user."
    >
      <AlertDialog
        open={open}
        onOpenChange={(v) => {
          setOpen(v)
          if (!v) reset()
        }}
      >
        <AlertDialogTrigger asChild>
          <Button type="button" variant="destructive" size="sm">
            Delete account
          </Button>
        </AlertDialogTrigger>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Delete your account?</AlertDialogTitle>
            <AlertDialogDescription>
              This soft-deletes your user. You won't be able to sign back in.
              An admin can purge your vault data later.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <fieldset className="space-y-3">
            <div className="space-y-1.5">
              <Label htmlFor="delete-password">Password</Label>
              <Input
                id="delete-password"
                type="password"
                autoComplete="current-password"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
              />
            </div>
            <label className="flex items-center gap-2 text-sm">
              <Checkbox
                checked={confirmed}
                onCheckedChange={(v) => setConfirmed(v === true)}
                aria-label="I understand this is irreversible"
              />
              I understand this is irreversible
            </label>
            {error && <p className="text-sm text-destructive">{error}</p>}
          </fieldset>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction
              disabled={!confirmed || password.length === 0 || deleter.isPending}
              onClick={(e) => {
                e.preventDefault()
                onDelete()
              }}
            >
              Delete
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </SettingsSectionCard>
  )
}
```

- [ ] **Step 4: Run test to verify pass**

```bash
cd backend/frontend && bun test danger-zone-section-local.test.tsx
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd backend
git add frontend/src/settings/account/danger-zone-section-local.tsx \
        frontend/src/settings/account/danger-zone-section-local.test.tsx
git commit -m "feat(settings): DangerZoneSectionLocal delete-self flow"
```

---

## Task 11: Frontend — `AccountPageLocal` shell

**Files:**
- Create: `backend/frontend/src/settings/account-page-local.tsx`
- Create: `backend/frontend/src/settings/account-page-local.test.tsx`

- [ ] **Step 1: Write the failing test**

Create `backend/frontend/src/settings/account-page-local.test.tsx`:

```tsx
import { describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'

vi.mock('./account/profile-section-local', () => ({
  ProfileSectionLocal: () => <div data-testid="profile" />,
}))
vi.mock('./account/appearance-section', () => ({
  AppearanceSection: () => <div data-testid="appearance" />,
}))
vi.mock('./account/email-readonly-section', () => ({
  EmailReadonlySection: () => <div data-testid="email" />,
}))
vi.mock('./account/password-section-local', () => ({
  PasswordSectionLocal: () => <div data-testid="password" />,
}))
vi.mock('./account/danger-zone-section-local', () => ({
  DangerZoneSectionLocal: () => <div data-testid="danger" />,
}))

import AccountPageLocal from './account-page-local'

describe('AccountPageLocal', () => {
  it('renders every section in order', () => {
    render(<AccountPageLocal />)
    expect(screen.getByRole('heading', { name: /account/i })).toBeInTheDocument()
    for (const id of ['profile', 'appearance', 'email', 'password', 'danger']) {
      expect(screen.getByTestId(id)).toBeInTheDocument()
    }
  })
})
```

- [ ] **Step 2: Run test to verify failure**

```bash
cd backend/frontend && bun test account-page-local.test.tsx
```

Expected: FAIL — import error.

- [ ] **Step 3: Implement the page**

Create `backend/frontend/src/settings/account-page-local.tsx`:

```tsx
import { ProfileSectionLocal } from './account/profile-section-local'
import { AppearanceSection } from './account/appearance-section'
import { EmailReadonlySection } from './account/email-readonly-section'
import { PasswordSectionLocal } from './account/password-section-local'
import { DangerZoneSectionLocal } from './account/danger-zone-section-local'

export default function AccountPageLocal() {
  return (
    <article className="space-y-6">
      <header>
        <h1 className="text-xl font-semibold text-foreground">Account</h1>
        <p className="mt-1 text-sm text-muted-foreground">
          Manage your profile, password, and account.
        </p>
      </header>
      <ProfileSectionLocal />
      <AppearanceSection />
      <EmailReadonlySection />
      <PasswordSectionLocal />
      <DangerZoneSectionLocal />
    </article>
  )
}
```

- [ ] **Step 4: Run test to verify pass**

```bash
cd backend/frontend && bun test account-page-local.test.tsx
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd backend
git add frontend/src/settings/account-page-local.tsx \
        frontend/src/settings/account-page-local.test.tsx
git commit -m "feat(settings): AccountPageLocal shell"
```

---

## Task 12: Frontend — Wire `account` route for local + simplify index redirect

**Files:**
- Modify: `backend/frontend/src/router.tsx`

- [ ] **Step 1: Edit `router.tsx`**

Locate the `lazy(...)` import block near line 29:

```tsx
const AccountPage = lazy(() => import('./settings/account-page'))
```

Replace with:

```tsx
const AccountPage = lazy(() =>
  config.authProvider === 'clerk'
    ? import('./settings/account-page')
    : import('./settings/account-page-local'),
)
```

Locate the index redirect at line ~75 (`config.authProvider === 'clerk' ? 'account' : 'api-keys'`) and replace with:

```tsx
<Navigate to="account" replace />
```

Locate the conditional `account` child route block (`...(config.authProvider === 'clerk' ? [...] : [])`) and replace with an unconditional entry:

```tsx
{
  path: 'account',
  element: (
    <Suspense fallback={<p className="text-muted-foreground">Loading…</p>}>
      <AccountPage />
    </Suspense>
  ),
},
```

- [ ] **Step 2: Type-check + tests**

```bash
cd backend/frontend && bun run build && bun test
```

Expected: build succeeds, all frontend tests pass.

- [ ] **Step 3: Commit**

```bash
cd backend
git add frontend/src/router.tsx
git commit -m "feat(router): unconditional /settings/account, lazy-branch by authProvider"
```

---

## Task 13: Manual smoke (no automation; verify in browser)

**Files:** none changed; verify only.

- [ ] **Step 1: Boot the self-host dev stack**

Follow `docs/context/saas-local-dev-workflow.md` — same workflow but the goal is `make selfhost-dev` (or `make saas-dev` with `AUTH_PROVIDER=local` set in `.env.local`). Confirm `http://localhost:5173/api/billing/config` reports `billing_enabled: false` and the auth provider is `local`.

- [ ] **Step 2: Sign in (or sign up) as a local user**

Confirm `/settings/account` loads as the default settings page.

- [ ] **Step 3: Edit display name → Save → reload**

Confirm the new name persists (`GET /api/me`).

- [ ] **Step 4: Change password**

Confirm you are redirected to `/sign-in` and the new password works.

- [ ] **Step 5: Delete account (use a throw-away member, not the only admin)**

Confirm you land on `/sign-in` and can no longer log in with that user.

- [ ] **Step 6: Last-admin guard**

As the sole admin, attempt delete → expect inline "only admin" error and no soft-delete.

- [ ] **Step 7: Commit the working manual-test note**

Nothing to commit if everything works. If anything fails, file a follow-up issue and fix in this PR.

---

## Task 14: Open PRs

- [ ] **Step 1: Push backend feature branch**

```bash
cd backend
git push -u origin feat/selfhost-account-settings
```

- [ ] **Step 2: Open the backend PR**

```bash
cd backend
gh pr create --title "feat(settings): self-host Account tab" --body "$(cat <<'EOF'
## Summary

- Adds `/settings/account` for self-hosters: edit display name, change password, delete account.
- Backend: `PATCH /api/me`, `DELETE /api/me`, plus `Accounts.update_profile/2`, `active_admin_count/0`, `delete_self/2`.
- Frontend: new `AccountPageLocal` mounted via lazy-branch in `router.tsx`; Clerk imports stay out of the local bundle.
- Last-admin guard prevents instance lock-out.

Spec: `engram-workspace/docs/superpowers/specs/2026-05-30-selfhost-account-settings-design.md`
Plan: `engram-workspace/docs/superpowers/plans/2026-05-30-selfhost-account-settings.md`

## Test plan
- [x] `mix test` green
- [x] `bun test` (frontend) green
- [x] Manual smoke per plan Task 13

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Push + open workspace PR for spec + plan**

```bash
cd ../engram-workspace
git push -u origin feat/selfhost-account-settings
gh pr create --title "docs: self-host account settings spec + plan" --body "Adds the design spec and implementation plan for the self-host Account tab. Tracks engram-app/engram#TBD."
```

- [ ] **Step 4: Cross-link the two PRs in their bodies**

After both URLs exist, edit each PR body to reference the other (`gh pr edit <num> --body ...`).

---

## Self-Review

**Spec coverage:**

| Spec section | Covered by |
|--------------|------------|
| Routing + Sidebar | Tasks 6, 12 |
| `PATCH /api/me` | Tasks 1, 4 |
| `DELETE /api/me` | Tasks 3, 4 |
| `Accounts.update_profile` | Task 1 |
| `Accounts.active_admin_count` | Task 2 |
| `Accounts.delete_self` | Task 3 |
| ProfileSectionLocal | Task 7 |
| EmailReadonlySection | Task 8 |
| PasswordSectionLocal | Task 9 |
| DangerZoneSectionLocal | Task 10 |
| AccountPageLocal | Task 11 |
| Reused AppearanceSection | Task 11 |
| Backend tests | Tasks 1-4 |
| Frontend tests | Tasks 6-11 |
| Manual smoke | Task 13 |
| PRs | Task 14 |

**Placeholder scan:** No "TBD", "TODO", or "implement later" sentinels remain. Every step shows the code or command.

**Type consistency:** Hook names match across tasks: `useUpdateProfile`, `useDeleteSelf`. Component names match: `ProfileSectionLocal`, `EmailReadonlySection`, `PasswordSectionLocal`, `DangerZoneSectionLocal`, `AccountPageLocal`. Backend function names match: `update_profile/2`, `active_admin_count/0`, `delete_self/2`. Error atoms match: `:invalid_password`, `:last_admin`. HTTP status codes match between controller and tests: 200, 204, 401, 403, 409, 422.
