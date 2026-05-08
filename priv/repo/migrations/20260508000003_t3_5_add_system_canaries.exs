defmodule Engram.Repo.Migrations.T35AddSystemCanaries do
  use Ecto.Migration

  @moduledoc """
  T3.5.5 / M3 — boot canary table.

  Append-only log of wrapped DEKs, one row per master-key generation.
  Each rotation writes a new row with a freshly-generated DEK wrapped
  by the new master. Boot-time verification reads the most-recent row
  and attempts to unwrap with ONLY the current master key — no
  `_PREVIOUS` fallback. Failure means the env's `ENCRYPTION_MASTER_KEY`
  is not the key used at the most recent rotation. Boot raises rather
  than start with a misconfigured key that would silently rely on
  `_PREVIOUS` and mask a failed master-key cutover.

  Also stores `dek_sha256` (a SHA256 of the canary's plaintext DEK) so
  the verify step double-checks the unwrap returned the original
  plaintext, not just any 32-byte blob the cipher happened to produce.
  """

  def change do
    create table(:system_canaries) do
      add :wrapped_dek, :binary, null: false
      add :dek_sha256, :binary, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:system_canaries, [:inserted_at])
  end
end
