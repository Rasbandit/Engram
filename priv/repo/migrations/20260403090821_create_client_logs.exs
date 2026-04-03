defmodule Engram.Repo.Migrations.CreateClientLogs do
  use Ecto.Migration

  def change do
    create table(:client_logs) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :ts, :utc_datetime, null: false
      add :level, :text, default: "info"
      add :category, :text, default: ""
      add :message, :text, default: ""
      add :stack, :text
      add :plugin_version, :text, default: ""
      add :platform, :text, default: ""

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:client_logs, [:user_id, :inserted_at], name: :idx_client_logs_user_created)
    create index(:client_logs, [:user_id, :level], name: :idx_client_logs_user_level)
  end
end
