defmodule Engram.Repo.Migrations.CreateUserLimitOverrides do
  use Ecto.Migration

  def up do
    create table(:user_limit_overrides) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :value, :map, null: false
      add :reason, :string, null: false
      add :set_by, :string, null: false
      add :set_at, :utc_datetime, default: fragment("now()"), null: false
      add :expires_at, :utc_datetime, null: true
    end

    create unique_index(:user_limit_overrides, [:user_id, :key])
    create index(:user_limit_overrides, [:expires_at], where: "expires_at IS NOT NULL")
    create index(:user_limit_overrides, [:user_id])

    # Backfill from existing user_overrides JSONB blob → per-(user, key) rows.
    # Pre-merge prod probe confirmed 0 rows on saas, so this is a no-op there;
    # included for any env that may have inserted scaffolding rows.
    execute """
    INSERT INTO user_limit_overrides (user_id, key, value, reason, set_by, set_at)
    SELECT o.user_id,
           k.key,
           jsonb_build_object('v', o.overrides -> k.key),
           COALESCE(o.reason, 'pre-v2 override'),
           'backfill:2026-05-20',
           o.created_at
    FROM user_overrides o
    CROSS JOIN LATERAL jsonb_object_keys(o.overrides) AS k(key)
    WHERE o.overrides -> k.key IS NOT NULL
    """

    # Grant app role permissions on new table + sequence (mirrors original user_overrides grants).
    execute "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE user_limit_overrides TO engram_app"
    execute "GRANT USAGE, SELECT ON SEQUENCE user_limit_overrides_id_seq TO engram_app"

    # Revoke + drop legacy table.
    execute "REVOKE ALL ON TABLE user_overrides FROM engram_app"
    drop table(:user_overrides)
  end

  def down do
    # NOTE: Recreates an EMPTY user_overrides table. Data is NOT restored.
    create table(:user_overrides) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :overrides, :map, null: false, default: %{}
      add :reason, :text
      timestamps(type: :utc_datetime, inserted_at: :created_at)
    end

    create unique_index(:user_overrides, [:user_id])

    execute "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE user_overrides TO engram_app"
    execute "GRANT USAGE, SELECT ON SEQUENCE user_overrides_id_seq TO engram_app"

    execute "REVOKE ALL ON TABLE user_limit_overrides FROM engram_app"
    drop table(:user_limit_overrides)
  end
end
