defmodule Engram.Repo.Migrations.AddRlsPolicies do
  use Ecto.Migration

  @tenant_tables ~w(notes chunks attachments api_keys)

  def up do
    # Create the runtime role (subject to RLS).
    # In dev, the migration user (engram) acts as owner and bypasses RLS.
    # In production, engram_app connects at runtime; engram_owner runs migrations.
    execute """
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'engram_app') THEN
        CREATE ROLE engram_app NOINHERIT LOGIN PASSWORD 'engram_app';
      END IF;
    END
    $$;
    """

    execute "GRANT USAGE ON SCHEMA public TO engram_app"
    execute "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO engram_app"
    execute "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO engram_app"

    # Set default privileges so future tables are also accessible
    execute "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO engram_app"
    execute "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO engram_app"

    # Enable RLS and create policies on tenant-scoped tables
    for table <- @tenant_tables do
      execute "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY"

      execute """
      CREATE POLICY tenant_isolation_#{table} ON #{table}
        USING (user_id::text = current_setting('app.current_tenant', true))
        WITH CHECK (user_id::text = current_setting('app.current_tenant', true))
      """
    end
  end

  def down do
    for table <- @tenant_tables do
      execute "DROP POLICY IF EXISTS tenant_isolation_#{table} ON #{table}"
      execute "ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY"
    end

    execute "REVOKE ALL ON ALL TABLES IN SCHEMA public FROM engram_app"
    execute "REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM engram_app"
    execute "REVOKE USAGE ON SCHEMA public FROM engram_app"

    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'engram_app') THEN
        DROP ROLE engram_app;
      END IF;
    END
    $$;
    """
  end
end
