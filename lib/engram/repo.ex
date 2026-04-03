defmodule Engram.Repo do
  use Ecto.Repo,
    otp_app: :engram,
    adapter: Ecto.Adapters.Postgres

  @tenant_tables ~w(notes chunks attachments api_keys)a

  @doc """
  Executes `fun` inside a transaction with RLS tenant context set.

  Sets both the process-dict guard (for prepare_query) and the
  PostgreSQL `SET LOCAL app.current_tenant` (for RLS enforcement).
  """
  def with_tenant(tenant_id, fun) do
    Process.put(:engram_tenant, tenant_id)

    try do
      transaction(fn ->
        # SET LOCAL doesn't support $1 parameter binding — it's a utility statement.
        # tenant_id is always a DB-generated integer, so to_string is safe.
        query!("SET LOCAL app.current_tenant = '#{tenant_id}'")
        # Drop to engram_app role so RLS policies are enforced.
        # Superusers bypass RLS even with FORCE — SET LOCAL ROLE scopes to this transaction.
        query!("SET LOCAL ROLE engram_app")
        result = fun.()
        # In Ecto Sandbox (tests), this transaction runs as a savepoint. PostgreSQL's
        # SET LOCAL is scoped to the full outer transaction, so RELEASE SAVEPOINT
        # would leak `engram_app` into the sandbox transaction. Resetting the role
        # INSIDE the transaction ensures the last SET LOCAL that persists is DEFAULT.
        # In production this runs inside a real transaction and is harmless.
        query!("RESET ROLE")
        result
      end)
    after
      Process.delete(:engram_tenant)
    end
  end

  @doc """
  Safety net — raises if a tenant-scoped table is queried without
  `with_tenant/2`. Uses process dict (zero-cost) rather than a DB query.
  """
  @impl true
  def prepare_query(_operation, query, opts) do
    if tenant_required?(query) and is_nil(Process.get(:engram_tenant)) and
         not Keyword.get(opts, :skip_tenant_check, false) do
      raise Engram.TenantError,
        message: "Tenant context not set! Use Repo.with_tenant/2 for tenant-scoped queries."
    end

    {query, opts}
  end

  defp tenant_required?(%Ecto.Query{from: %{source: {table, _}}}) do
    String.to_existing_atom(table) in @tenant_tables
  rescue
    ArgumentError -> false
  end

  defp tenant_required?(_), do: false
end
