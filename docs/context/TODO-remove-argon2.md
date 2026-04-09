# TODO: Remove Argon2 and Legacy Password Auth

## Context

Clerk handles all user authentication. The `password_hash` column and Argon2 dependency are legacy from pre-Clerk auth. They're no longer used in any production auth flow — Clerk JWTs and API keys are the only auth mechanisms.

The test factory (`test/support/factory.ex`) still calls `Argon2.hash_pwd_salt("password123")` for every `insert(:user)`, which was the main cause of slow tests (Argon2 is intentionally expensive at ~300ms per hash). We've mitigated this with `config :argon2_elixir, t_cost: 1, m_cost: 8` in `config/test.exs`, but the real fix is removing the dependency entirely.

## Steps

1. **Verify no production code uses password auth**
   - [ ] Grep for `Argon2` usage outside of tests and factory
   - [ ] Grep for `password_hash` reads in auth flows
   - [ ] Confirm `/api/users/login` and `/api/users/register` routes are dead or removed
   - [ ] Check if any legacy JWTs in the wild still depend on password-based login

2. **Remove the password_hash column**
   - [ ] Create migration: `ALTER TABLE users DROP COLUMN password_hash`
   - [ ] Update `Engram.Accounts.User` schema — remove `:password_hash` field
   - [ ] Update `user_factory` — remove `Argon2.hash_pwd_salt` call

3. **Remove login/register routes**
   - [ ] Remove `POST /api/users/login` and `POST /api/users/register` from router
   - [ ] Remove associated controller actions
   - [ ] Remove rate limit tests that test login/register rate limiting (or retarget to other endpoints)

4. **Remove Argon2 dependency**
   - [ ] Remove `:argon2_elixir` from `mix.exs` deps
   - [ ] Remove `config :argon2_elixir` from `config/test.exs`
   - [ ] Run `mix deps.unlock argon2_elixir && mix deps.get`

5. **Clean up**
   - [ ] Remove any password validation logic in `Accounts` context
   - [ ] Update tests that reference passwords
   - [ ] Delete this TODO doc

## Risk

- If any users have API keys generated through the legacy password login flow, those keys remain valid (they're stored by hash, independent of password auth)
- Clerk is the sole auth provider — if Clerk goes down, there's no fallback. This is already the case in production today.
