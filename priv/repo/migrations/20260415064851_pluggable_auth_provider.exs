defmodule Engram.Repo.Migrations.PluggableAuthProvider do
  use Ecto.Migration

  def change do
    # Rename clerk-specific column to generic external_id
    rename table(:users), :clerk_id, to: :external_id

    # Add local password auth columns
    alter table(:users) do
      add :password_hash, :string, null: true
      add :role, :string, null: false, default: "member"
    end

    # Refresh tokens for local auth (token rotation / family invalidation)
    create table(:refresh_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token_hash, :string, null: false
      add :family_id, :string, null: false
      add :expires_at, :utc_datetime, null: false
      add :revoked_at, :utc_datetime, null: true

      timestamps(type: :utc_datetime, updated_at: false, inserted_at: :created_at)
    end

    create unique_index(:refresh_tokens, [:token_hash])
    create index(:refresh_tokens, [:family_id])
    create index(:refresh_tokens, [:user_id])
  end
end
