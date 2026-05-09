defmodule Engram.Crypto.RotationLock do
  @moduledoc """
  T3.7 — per-user rotation lock. Held on `users.dek_rotation_locked_at`
  with a Postgres advisory lock guarding the acquire-or-takeover
  transition.

  Lifecycle:

      acquire(user_id, target_dek_version: 2)  # sets locked_at = now()
      ... rotation work ...
      release(user_id)                          # clears locked_at

  Stale-lock takeover: if `locked_at` is older than `@stale_after_seconds`,
  a new `acquire/2` overwrites the timestamp (assumes prior attempt crashed).
  The advisory lock is auto-released on transaction commit/rollback because
  we use `pg_advisory_xact_lock`.
  """

  import Ecto.Query, only: [from: 2]

  alias Engram.Accounts.User
  alias Engram.Repo

  @stale_after_seconds 10 * 60

  @spec acquire(integer(), keyword()) ::
          {:ok, DateTime.t()} | {:error, :rotation_in_progress | :not_found}
  def acquire(user_id, _opts \\ []) when is_integer(user_id) do
    Repo.transaction(fn ->
      # Postgres advisory lock keyed on the user — serializes concurrent
      # acquire/2 callers without holding a row-level lock that would
      # also block the rotation worker's per-batch FOR UPDATE on the same row.
      key = :erlang.phash2({user_id, :dek_rotation}, 2_147_483_647)
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [key])

      case Repo.one(from(u in User, where: u.id == ^user_id), skip_tenant_check: true) do
        nil ->
          Repo.rollback(:not_found)

        %User{dek_rotation_locked_at: nil} = u ->
          set_locked(u)

        %User{dek_rotation_locked_at: at} = u ->
          if stale?(at) do
            set_locked(u)
          else
            Repo.rollback(:rotation_in_progress)
          end
      end
    end)
  end

  @spec release(integer()) :: :ok
  def release(user_id) when is_integer(user_id) do
    {1, _} =
      from(u in User, where: u.id == ^user_id)
      |> Repo.update_all([set: [dek_rotation_locked_at: nil]], skip_tenant_check: true)

    :ok
  end

  @spec locked?(integer()) :: boolean()
  def locked?(user_id) when is_integer(user_id) do
    Repo.one(
      from(u in User, where: u.id == ^user_id, select: not is_nil(u.dek_rotation_locked_at)),
      skip_tenant_check: true
    ) || false
  end

  # ── private ─────────────────────────────────────────────────────────────

  defp set_locked(%User{} = user) do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    {1, _} =
      from(u in User, where: u.id == ^user.id)
      |> Repo.update_all([set: [dek_rotation_locked_at: now]], skip_tenant_check: true)

    now
  end

  defp stale?(%DateTime{} = at) do
    DateTime.diff(DateTime.utc_now(), at, :second) > @stale_after_seconds
  end
end
