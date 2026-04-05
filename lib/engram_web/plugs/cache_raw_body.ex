defmodule EngramWeb.Plugs.CacheRawBody do
  @moduledoc """
  Caches the raw request body in conn.assigns[:raw_body] for webhook signature verification.
  Must be used as a Plug.Parsers body_reader.
  """

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        conn = Plug.Conn.assign(conn, :raw_body, body)
        {:ok, body, conn}

      {:more, body, conn} ->
        {:more, body, conn}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
