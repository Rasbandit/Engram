# Self-Host Account Settings — Design

Date: 2026-05-30
Status: Draft (pending user review)
Repos touched: `engram-app/engram` (backend + frontend in one PR)

## Problem

`/settings` exposes an Account tab only when `config.authProvider === 'clerk'`. Self-hosters (`authProvider === 'local'`) land on `/settings/api-keys` with no way to:

- Edit their display name
- Change their password from the UI (the endpoint exists, the form does not)
- Delete their own account

The backend already has every primitive needed except a profile-update path, a self-delete path, and a "last admin" guard.

## Goals

1. Self-hoster has a first-class Account tab matching the cloud information architecture.
2. No new domain logic — thin glue over `Engram.Accounts`.
3. Soft-delete uses the existing `users.deleted_at` column and the existing login chokepoint that blocks deleted users.
4. Single PR, backend + frontend together (per `feedback_single_pr_all_changes`).

## Non-Goals (v1)

- Sessions list / per-device revoke
- Email change (requires email-verification flow that does not exist self-host)
- Avatar upload
- OAuth connected accounts (n/a for local auth)
- Hard delete inline or background purge of user data (notes/vaults stay until admin purge; out of scope here)

## Architecture

### Routing

| Path | Self-host | Clerk |
|------|-----------|-------|
| `/settings` | redirects to `account` | redirects to `account` (unchanged) |
| `/settings/account` | new — local variant | existing Clerk page |
| `/settings/vaults` | unchanged | unchanged |
| `/settings/api-keys` | unchanged | unchanged |
| `/settings/billing` | n/a (`billingEnabled=false`) | unchanged |
| `/settings/admin` | unchanged (admin role only) | n/a |

`router.tsx`:

- `account` becomes an unconditional child route.
- `lazy()` branches on `config.authProvider`:
  - `'clerk'` → `./settings/account-page.tsx` (current)
  - `'local'` → `./settings/account-page-local.tsx` (new)
- Index redirect simplifies from `config.authProvider === 'clerk' ? 'account' : 'api-keys'` to `'account'`.

This split keeps `@clerk/clerk-react` imports out of the local bundle path.

### Sidebar

`buildSettingsSections(authProvider, billingEnabled, isAdmin)`:

- Drop the `authProvider === 'clerk'` gate around Account; always prepend `{ to: 'account', label: 'Account' }`.
- Order unchanged: Account → Vaults → API Keys → Billing? → Admin?

### Backend endpoints

All under existing `scope "/api"` authed pipeline (router.ex:143), no new plug.

#### `PATCH /api/me`

- Body: `{display_name: string|null}` (trimmed; empty → `nil`)
- Auth: existing
- 200: `{user: %{id, email, role, display_name, created_at, updated_at}}`
- 422: validation failure (e.g. length cap)

Calls `Accounts.update_profile(user, attrs)`.

#### `DELETE /api/me`

- Body: `{password: string}`
- Flow:
  1. `Accounts.verify_password(user.email, password)` — 403 `{error: "invalid_password"}` on mismatch
  2. If `user.role == :admin`, `Accounts.count_active_admins() == 1` → 409 `{error: "last_admin"}`
  3. `Repo.transaction`:
     - set `users.deleted_at = now()`
     - `Accounts.revoke_all_user_tokens(user)`
     - delete all `api_keys` rows for this user (hard delete — soft-deleting a credential row has no benefit)
  4. 204 No Content
- The existing login chokepoint (`verify_password` returns `{:error, :deleted}` when `not is_nil(user.deleted_at)`) means subsequent logins are blocked without further work.

#### Accounts context additions

- `update_profile(%User{}, %{display_name: ...}) :: {:ok, User.t()} | {:error, Changeset.t()}`
- `count_active_admins() :: non_neg_integer()` — `where role == :admin and is_nil(deleted_at)`, `skip_tenant_check: true`
- `delete_self(%User{}, password) :: :ok | {:error, :invalid_password | :last_admin}` — wraps the transactional flow above

### Frontend sections

New page `settings/account-page-local.tsx`:

```tsx
<article className="space-y-6">
  <header>
    <h1>Account</h1>
    <p>Manage your profile, password, and account.</p>
  </header>
  <ProfileSectionLocal />
  <AppearanceSection />        {/* reused as-is from settings/account/ */}
  <EmailReadonlySection />
  <PasswordSectionLocal />
  <DangerZoneSectionLocal />
</article>
```

New files (all under `settings/account/`):

- `profile-section-local.tsx` — single field `display_name`. `useMutation` → `PATCH /api/me` → invalidates `useMe` query → toast.
- `email-readonly-section.tsx` — pulls from `useMe`. Read-only field + copy-to-clipboard button + microcopy *"To change your email, contact your admin."*
- `password-section-local.tsx` — `old_password`, `new_password`, `new_password_confirm`. `POST /api/auth/password/change`. On 200: toast → call existing local-auth signout helper → redirect `/sign-in`. (Backend already revokes refresh tokens on password change.)
- `danger-zone-section-local.tsx` — destructive `<Button variant="destructive">Delete account</Button>` → `AlertDialog` with password input + checkbox confirmation. On submit: `DELETE /api/me`. On 200: clear local auth state, redirect `/sign-in`. On 409 `last_admin`: inline error linking to `/settings/admin`. On 403 `invalid_password`: inline error.

Updated files:

- `settings/sections.ts` — drop Clerk gate on Account.
- `router.tsx` — unconditional `account` route, lazy-branched page.

### Reused as-is

- `AppearanceSection` — no Clerk dependency, already a local component.
- `SettingsSectionCard` — shared shell, unchanged.

## Data Flow — Delete Account

```
[UI: DangerZone] --click--> [AlertDialog asks password + checkbox]
   |
   |  POST DELETE /api/me {password}
   v
[UsersController.delete_self]
   |
   v
[Accounts.delete_self]
   |--verify_password--> 403 invalid_password
   |--count_active_admins--> 409 last_admin
   |
   v
[Repo.transaction]
   set users.deleted_at = now()
   revoke_all_user_tokens(user)
   delete from api_keys where user_id = user.id
   v
[204] -> [UI clears auth state -> /sign-in]
```

Login chokepoint already blocks `not is_nil(deleted_at)`, so a forgotten cookie can't re-auth.

## Error Handling

Frontend `useMutation` `onError` → `toast.error(humanizeError(err))`. Inline form errors for field-specific failures (`invalid_password`, `last_admin`, validation `details.display_name`). 5xx → generic toast + Sentry capture (already wired).

Backend errors:

| Endpoint | Code | Body |
|----------|------|------|
| PATCH /api/me | 422 | `{error: "validation_failed", details: %{display_name: [...]}}` |
| DELETE /api/me | 403 | `{error: "invalid_password"}` |
| DELETE /api/me | 409 | `{error: "last_admin"}` |

## Testing

### Backend (ExUnit)

- `Engram.AccountsTest`:
  - `update_profile/2` happy path, nil-clears, length cap
  - `count_active_admins/0` ignores deleted, ignores non-admin
  - `delete_self/2` happy path → user soft-deleted, tokens revoked, api_keys gone
  - `delete_self/2` returns `:invalid_password`, `:last_admin`
- `EngramWeb.UsersControllerTest`:
  - PATCH 200/401/422
  - DELETE 204/401/403/409
  - DELETE 204 then GET /api/me 401 (token revoked)

### Frontend (RTL)

- `profile-section-local.test.tsx` — submit, mutation, success toast, error inline
- `email-readonly-section.test.tsx` — renders email, copy button
- `password-section-local.test.tsx` — mismatch validation, submit, signout side-effect
- `danger-zone-section-local.test.tsx` — open dialog, password required, submit, 409 last-admin shows admin link
- `sections.test.ts` — Account present for `local`
- `account-page-local.test.tsx` — renders all sections

### E2E

Not required v1 — sections are individually covered by RTL + backend tests. Mark a follow-up issue if a full sign-up → edit-profile → delete loop is desired.

## Migration / Rollout

- No schema migration. `users.display_name` and `users.deleted_at` already exist.
- No feature flag. Self-host build picks up the new tab on next deploy.
- Backwards-compat: clerk users see no change (their `account-page.tsx` unchanged; route behavior identical).

## Open Questions

None at write time. If review surfaces any, fold them in before implementation plan.

## Out-of-Spec Follow-ups (issues to file after merge)

- Sessions list + revoke (multi-device management)
- Email change with verification (depends on self-host email-verification flow)
- Avatar upload (depends on attachment storage layout)
- Background data purge job for soft-deleted users
