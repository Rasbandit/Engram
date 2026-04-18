defmodule Engram.Repo.Migrations.AddVaultEncryptionColumns do
  use Ecto.Migration

  def change do
    alter table(:vaults) do
      add :encrypted, :boolean, default: false, null: false
      add :encrypted_at, :utc_datetime_usec
      add :encryption_status, :string, default: "none", null: false
      add :decrypt_requested_at, :utc_datetime_usec
      add :last_toggle_at, :utc_datetime_usec
    end
  end
end
