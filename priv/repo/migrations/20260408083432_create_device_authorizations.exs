defmodule Engram.Repo.Migrations.CreateDeviceAuthorizations do
  use Ecto.Migration

  def change do
    create table(:device_authorizations) do
      add :device_code, :string, null: false
      add :user_code, :string, null: false
      add :client_id, :string, null: false
      add :user_id, references(:users, on_delete: :delete_all)
      add :vault_id, references(:vaults, on_delete: :delete_all)
      add :status, :string, null: false, default: "pending"
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:device_authorizations, [:device_code])
    create unique_index(:device_authorizations, [:user_code])
    create index(:device_authorizations, [:expires_at])
  end
end
