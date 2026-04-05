defmodule EngramWeb.Plugs.Auth do
  @moduledoc """
  Authentication plug. Supports three auth methods:

  1. API key: `Authorization: Bearer engram_xxx` — for plugin sync, MCP, scripts
  2. Clerk JWT: `Authorization: Bearer <jwt-with-kid>` — for web app (RS256, JWKS)
  3. Legacy JWT: `Authorization: Bearer <jwt-without-kid>` — for backward compat (HS256)

  Sets `conn.assigns.current_user` on success, halts with 401 on failure.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, user} <- authenticate(conn) do
      assign(conn, :current_user, user)
    else
      {:error, _reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
        |> halt()
    end
  end

  defp authenticate(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> Engram.Auth.TokenResolver.resolve(token)
      _ -> {:error, :no_auth}
    end
  end
end
