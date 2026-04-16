defmodule Engram.Auth.Providers.Clerk do
  @moduledoc """
  Clerk auth provider — verifies RS256 JWTs via JWKS public keys.
  Used in SaaS deployment. Credentials-based auth is not supported.
  """

  @behaviour Engram.Auth.Provider

  @impl true
  def verify_token(token) do
    case Engram.Auth.ClerkToken.verify_clerk_jwt(token) do
      {:ok, claims} ->
        case {claims["sub"], claims["email"]} do
          {ext_id, email} when is_binary(ext_id) and is_binary(email) ->
            {:ok, %{external_id: ext_id, email: email}}

          _ ->
            {:error, :missing_claims}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def authenticate_credentials(_email, _password), do: {:error, :not_supported}

  @impl true
  def register_user(_email, _password, _opts), do: {:error, :not_supported}

  @impl true
  def supports_credentials?, do: false

  @impl true
  def resolve_user(external_id, email) do
    Engram.Accounts.find_or_create_by_external_id(external_id, %{email: email})
  end
end
