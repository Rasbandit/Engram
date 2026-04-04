defmodule Engram.Repo.Migrations.UpgradeTimestampsToUsec do
  use Ecto.Migration

  def change do
    # Notes — sync-critical timestamps need microsecond precision
    # to avoid missed updates when changes happen within the same second.
    alter table(:notes) do
      modify :inserted_at, :utc_datetime_usec, from: :utc_datetime
      modify :updated_at, :utc_datetime_usec, from: :utc_datetime
      modify :deleted_at, :utc_datetime_usec, from: :utc_datetime
    end
  end
end
