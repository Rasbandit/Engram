defmodule EngramWeb.Plugs.Auth do
  @moduledoc """
  Authentication plug. Supports two auth methods:

  1. API key: `Authorization: Bearer engram_xxx` — for plugin sync
  2. JWT session: `engram_session` cookie — for web UI

  Sets `conn.assigns.current_user` on success, halts with 401 on failure.
  """

  import Plug.Conn
  alias Engram.Accounts

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
      ["Bearer " <> token] -> authenticate_token(token)
      _ -> {:error, :no_auth}
    end
  end

  defp authenticate_token("engram_" <> _ = api_key) do
    Accounts.validate_api_key(api_key)
  end

  defp authenticate_token(jwt) do
    with {:ok, claims} <- Accounts.verify_jwt(jwt),
         user_id when is_integer(user_id) <- claims["user_id"] do
      {:ok, Accounts.get_user!(user_id)}
    else
      _ -> {:error, :invalid_token}
    end
  end
end
