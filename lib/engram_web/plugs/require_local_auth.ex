defmodule EngramWeb.Plugs.RequireLocalAuth do
  @moduledoc """
  Rejects requests with 404 when AUTH_PROVIDER is not :local.

  Guards local auth endpoints (register, login, refresh, logout) at runtime
  so they are unreachable in Clerk deployments regardless of compile-time config.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if Engram.Auth.supports_credentials?() do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(404, Jason.encode!(%{error: "not_found"}))
      |> halt()
    end
  end
end
