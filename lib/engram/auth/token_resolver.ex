defmodule Engram.Auth.TokenResolver do
  @moduledoc """
  Shared token→user resolution used by both the Auth plug and UserSocket.

  Handles three auth methods in order:
    1. API key  — `engram_` prefix
    2. Clerk JWT — RS256 JWT with a `kid` in the header (JWKS-verified)
    3. Legacy JWT — HS256 JWT without `kid` (symmetric secret)

  Returns `{:ok, %User{}}` or `{:error, reason}`.
  """

  alias Engram.Accounts

  @spec resolve(any()) ::
          {:ok, Accounts.User.t()}
          | {:ok, Accounts.User.t(), Accounts.ApiKey.t()}
          | {:error, atom()}

  def resolve("engram_" <> _ = raw_key) do
    case Accounts.validate_api_key(raw_key) do
      {:ok, user, api_key} -> {:ok, user, api_key}
      {:error, _} = err -> err
    end
  end

  def resolve(token) when is_binary(token) do
    if clerk_jwt?(token) do
      authenticate_clerk_jwt(token)
    else
      authenticate_legacy_jwt(token)
    end
  end

  def resolve(_), do: {:error, :invalid_token}

  # ---- private ----

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
      {:error, reason} ->
        require Logger
        Logger.warning("Clerk JWT auth failed: #{inspect(reason)}")
        {:error, :invalid_clerk_token}

      other ->
        require Logger
        Logger.warning("Clerk JWT auth failed at claim extraction: #{inspect(other)}")
        {:error, :invalid_clerk_token}
    end
  end

  defp authenticate_legacy_jwt(jwt) do
    with {:ok, claims} <- Accounts.verify_jwt(jwt),
         user_id when is_integer(user_id) <- claims["user_id"],
         %Accounts.User{} = user <- Accounts.get_user(user_id) do
      {:ok, user}
    else
      _ -> {:error, :invalid_token}
    end
  end
end
