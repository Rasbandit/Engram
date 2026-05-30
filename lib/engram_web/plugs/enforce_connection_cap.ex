defmodule EngramWeb.Plugs.EnforceConnectionCap do
  @moduledoc """
  Mounted on `POST /api/oauth/authorize/consent`. Before minting a new
  refresh-token family, looks up the target `oauth_clients.kind`, counts
  the user's active grants of that kind, and halts 402 if minting one
  more would exceed the per-tier cap.

  The cap key is derived from kind: `:obsidian_connections_cap` or
  `:mcp_connections_cap`. Free defaults to 1 of each; paid tiers default
  to nil (unlimited).

  Rejection body:
      {"error": "connection_cap_reached",
       "kind": "<obsidian|mcp>",
       "current": <integer>,
       "limit": <integer>,
       "upgrade_url": "/settings/billing"}

  Missing or unknown `client_id`: HTTP 400 with
      {"error": "missing_or_invalid_client_id"}

  Refresh-token rotation does NOT come through this plug — rotation
  consumes the old token in `Engram.OAuth.exchange_refresh_token/2`
  without adding a new connection, so caps are not re-checked on every
  request.
  """

  import Plug.Conn
  import Ecto.Query

  alias Engram.{Billing, Connections, Repo}
  alias Engram.OAuth.Client

  @upgrade_url "/settings/billing"

  def init(opts), do: opts

  def call(%Plug.Conn{assigns: %{current_user: user}, params: params} = conn, _opts) do
    case lookup_client(params) do
      {:ok, %Client{kind: kind_str}} ->
        kind = kind_atom(kind_str)
        key = cap_key(kind_str)
        current = Connections.count_active(user.id, kind)
        limit = Billing.effective_limit(user, key)

        cond do
          limit in [:unlimited, nil] ->
            conn

          is_integer(limit) and current < limit ->
            conn

          true ->
            send_json(conn, 402, %{
              error: "connection_cap_reached",
              kind: kind_str,
              current: current,
              limit: limit,
              upgrade_url: @upgrade_url
            })
        end

      :error ->
        send_json(conn, 400, %{error: "missing_or_invalid_client_id"})
    end
  end

  def call(_conn, _opts) do
    raise "EnforceConnectionCap requires :current_user assigned by upstream auth plug"
  end

  # Map kind string to the atom used by Connections.count_active/2. Using a
  # literal map avoids String.to_existing_atom/1 failure when the atom hasn't
  # been touched yet in a given beam node (e.g. unit test isolation).
  defp kind_atom("obsidian"), do: :obsidian
  defp kind_atom("mcp"), do: :mcp

  # Same motivation: avoid to_existing_atom for the LimitKey atoms.
  defp cap_key("obsidian"), do: :obsidian_connections_cap
  defp cap_key("mcp"), do: :mcp_connections_cap

  defp lookup_client(%{"client_id" => client_id}) when is_binary(client_id) do
    case Ecto.UUID.cast(client_id) do
      {:ok, _} ->
        case Repo.one(from(c in Client, where: c.client_id == ^client_id),
               skip_tenant_check: true
             ) do
          nil -> :error
          client -> {:ok, client}
        end

      :error ->
        :error
    end
  end

  defp lookup_client(_), do: :error

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end
end
