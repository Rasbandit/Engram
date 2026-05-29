defmodule Engram.Repo.Migrations.AddUserSuspendedAt do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :suspended_at, :utc_datetime_usec
    end
  end
end
