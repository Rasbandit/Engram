defmodule Engram.Repo.Migrations.AddClerkAuth do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :clerk_id, :text
    end

    create unique_index(:users, [:clerk_id], where: "clerk_id IS NOT NULL")

    # Make password_hash nullable for Clerk-only users
    execute(
      "ALTER TABLE users ALTER COLUMN password_hash DROP NOT NULL",
      "ALTER TABLE users ALTER COLUMN password_hash SET NOT NULL"
    )
  end
end
