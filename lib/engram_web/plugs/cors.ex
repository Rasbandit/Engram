defmodule EngramWeb.Plugs.CORS do
  @moduledoc """
  Simple CORS plug — allows all origins (auth is via Bearer token, not cookies).
  Handles OPTIONS preflight and adds headers to all responses.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = put_cors_headers(conn)

    if conn.method == "OPTIONS" do
      conn
      |> send_resp(200, "")
      |> halt()
    else
      conn
    end
  end

  defp put_cors_headers(conn) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET, POST, PUT, DELETE, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "authorization, content-type")
    |> put_resp_header("access-control-max-age", "86400")
  end
end
