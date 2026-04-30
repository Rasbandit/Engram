defmodule Engram.Repo.Migrations.AddUserEncryptionToggleCooldown do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :encryption_toggle_cooldown_days, :integer
    end
  end
end
