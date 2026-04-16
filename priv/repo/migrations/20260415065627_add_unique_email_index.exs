defmodule Engram.Repo.Migrations.AddUniqueEmailIndex do
  use Ecto.Migration

  def change do
    drop_if_exists unique_index(:users, [:email])
    create unique_index(:users, ["lower(email)"], name: :users_email_lower_index)
  end
end
