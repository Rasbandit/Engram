defmodule Engram.Repo.Migrations.DropPasswordHash do
  use Ecto.Migration

  def change do
    alter table(:users) do
      remove :password_hash, :text
    end
  end
end
