defmodule Engram.Repo.Migrations.AddUserEncryptionColumns do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :encrypted_dek, :binary
      add :dek_version, :integer, default: 1, null: false
      add :key_provider, :string, default: "local", null: false
    end
  end
end
