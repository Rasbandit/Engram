defmodule EngramWeb.Plugs.Auth do
  @moduledoc """
  Authentication plug. Supports three auth methods:

  1. API key: `Authorization: Bearer engram_xxx` — for plugin sync, MCP, scripts
  2. Clerk JWT: `Authorization: Bearer <jwt-with-kid>` — for web app (RS256, JWKS)
  3. Legacy JWT: `Authorization: Bearer <jwt-without-kid>` — for backward compat (HS256)

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
    if clerk_jwt?(jwt) do
      authenticate_clerk_jwt(jwt)
    else
      authenticate_legacy_jwt(jwt)
    end
  end

  defp clerk_jwt?(token) do
    case String.split(token, ".") do
      [header, _, _] ->
        case Base.url_decode64(header, padding: false) do
          {:ok, json} ->
            case Jason.decode(json) do
              {:ok, %{"kid" => _}} -> true
              _ -> false
            end

          _ ->
            false
        end

      _ ->
        false
    end
  end

  defp authenticate_clerk_jwt(token) do
    with {:ok, claims} <- Engram.Auth.ClerkToken.verify_clerk_jwt(token),
         clerk_id when is_binary(clerk_id) <- claims["sub"],
         email when is_binary(email) <- claims["email"] do
      Accounts.find_or_create_by_clerk_id(clerk_id, %{email: email})
    else
      _ -> {:error, :invalid_clerk_token}
    end
  end

  defp authenticate_legacy_jwt(jwt) do
    with {:ok, claims} <- Accounts.verify_jwt(jwt),
         user_id when is_integer(user_id) <- claims["user_id"],
         %Engram.Accounts.User{} = user <- Accounts.get_user(user_id) do
      {:ok, user}
    else
      _ -> {:error, :invalid_token}
    end
  end
end
