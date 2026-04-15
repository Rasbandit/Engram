defmodule Engram.Repo.Migrations.AddUniqueEmailIndex do
  use Ecto.Migration

  def change do
    create_if_not_exists unique_index(:users, [:email])
  end
end
