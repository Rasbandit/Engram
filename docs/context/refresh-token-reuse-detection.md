# Refresh token rotation — reuse detection + leeway (build plan)

_Status: built 2026-05-28 on `fix/refresh-token-grace-window` (Engram PR #341),
v0.5.245. Backend repo (`engram`)._

## Why

Device refresh tokens (`DeviceFlow`) are single-use rotating, 90-day TTL, 15-min
access tokens. The Obsidian plugin previously held only the access token in
memory, so every reload forced a refresh that rotated the single-use token; a
lost rotation save (BRAT reload mid-refresh, etc.) bricked the session → forced
re-login. Two fixes:

- **Plugin (Engram-obsidian PR #84, shipped):** persist the access token so
  reloads within its 15-min life skip the refresh entirely (no rotation).
- **Backend (this plan):** make rotation robust + secure per RFC 9700.

## Research verdict (RFC 9700 §4.14.2 + Auth0/Okta docs)

Best practice for public clients without sender-constrained tokens is **refresh
token rotation + reuse detection with token-family revocation**, layered with a
**short leeway/overlap window** for benign retries/concurrency:

- On reuse of an *already-invalidated* token **outside** the leeway → breach →
  **revoke the entire token family** → force re-login. (RFC 9700 MUST; Auth0
  "Automatic Reuse Detection"; Okta "grace period".)
- **Within** the leeway window, accept the immediately-previous token, issue a
  new one, skip breach detection. (Auth0 `leeway` / "Rotation Overlap Period";
  default 0, "shortest amount of time" recommended.)

PR #341 added the leeway half (`@refresh_grace_seconds 60`) but **not** the
family-revocation half — that is the gap to close. Keep the leeway; add families.

Sources: RFC 9700 §4.14.2 (ietf.org/rfc/rfc9700.html); Auth0 "Refresh Token
Rotation" + "Configure Refresh Token Rotation" (`leeway` attr); WorkOS "We read
RFC 9700".

## Current state

- `lib/engram/auth/device_flow.ex` — `refresh_access_token/1` accepts a token
  revoked within `@refresh_grace_seconds` (60s); stamps `revoked_at` only on
  first use. **No family tracking, no reuse-detection revocation.**
- `Engram.Auth.DeviceRefreshToken` schema — no `family_id` column.
- PR #341 (`fix/refresh-token-grace-window`) open with the leeway-only change +
  tests; CI green. Decide: extend this PR with families, or supersede it.

## Build plan (TDD, one step per commit)

1. **Migration** — add `family_id :uuid` to `device_refresh_tokens` (+ index).
   Backfill: give every existing row its own fresh `family_id` (each existing
   token = its own family). Add to the schema + changeset.
2. **`create_refresh_token/3`** — accept an optional `family_id`; generate a new
   uuid when nil (new login), inherit it on rotation. Device authorize/exchange
   path mints a new family; `refresh_access_token` passes the old token's family.
3. **`refresh_access_token/1` reuse detection** — look up by hash where
   `expires_at > now` (regardless of `revoked_at`). Then:
   - not found → `{:error, :invalid_refresh_token}`
   - active (`revoked_at` nil) → rotate: revoke it, issue child in same family.
   - revoked **within** leeway → benign retry: issue child in same family, no
     revocation (this is the existing grace path).
   - revoked **outside** leeway (or an older token) → **reuse detected**:
     **hard-`delete_all` the entire family** (`where family_id == ^fid`), return
     `{:error, :invalid_refresh_token}`. **Delete, not `update_all` set
     `revoked_at`** — a freshly-revoked current token would land *inside* the
     leeway window and be misclassified as a benign retry on its next
     presentation, defeating the revocation. Deleting removes that ambiguity;
     `Logger.warning` the breach (family_id + user_id) so the audit trail
     survives the row deletion.
   - Renamed `@refresh_grace_seconds` → `@refresh_leeway_seconds`; trimmed 60s →
     30s (Auth0 recommends shortest; plugin reload races resolve in <1s).
4. **Tests** (`test/engram/auth/device_flow_test.exs` +
   `test/engram_web/controllers/device_auth_controller_test.exs`):
   - normal rotation chain still works;
   - reuse within leeway → ok (exists);
   - **reuse outside leeway → family revoked**: after reuse, the *valid current*
     token in that family is also rejected (the security-defining test);
   - boundary at exactly the leeway cutoff; expired-AND-revoked still rejected;
   - unknown token → invalid (exists).
5. Version bump `mix.exs` (pre-push hook enforces it). Format + credo. CI green.

## Notes / gotchas

- `skip_tenant_check: true` is fine here — lookup is keyed on the 256-bit
  `token_hash`; issued tokens inherit `old_token.user_id`/`vault_id`, so a token
  can only mint tokens for its own owner. Family invalidation `delete_all` is
  scoped by `family_id`, also owner-bound (a family never crosses users).
- Concurrency: two concurrent refreshes of the same active token both pass the
  lookup before either stamps `revoked_at`. Acceptable within leeway (both are
  the "previous token"); they fork into the same family, and the unused branch
  ages out. Document it; don't try to serialize at the DB layer unless it bites.
- Client (plugin) already: persists access token (PR #84), dedups concurrent
  refreshes via `inflightRefresh`, awaits rotation persistence before use.
