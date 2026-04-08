defmodule Engram.Repo.Migrations.CreateDeviceRefreshTokens do
  use Ecto.Migration

  def change do
    create table(:device_refresh_tokens) do
      add :token_hash, :string, null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :vault_id, references(:vaults, on_delete: :delete_all), null: false
      add :expires_at, :utc_datetime, null: false
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:device_refresh_tokens, [:token_hash])
    create index(:device_refresh_tokens, [:user_id])
  end
end
