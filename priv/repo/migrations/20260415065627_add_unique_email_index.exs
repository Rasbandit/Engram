defmodule Engram.Repo.Migrations.AddUniqueEmailIndex do
  use Ecto.Migration

  def up do
    execute "DROP INDEX IF EXISTS users_email_index"
    create unique_index(:users, ["lower(email)"], name: :users_email_lower_index)
  end

  def down do
    drop_if_exists unique_index(:users, ["lower(email)"], name: :users_email_lower_index)
    create_if_not_exists unique_index(:users, [:email])
  end
end
