defmodule Engram.Auth.ClerkToken do
  @moduledoc """
  Verifies Clerk JWTs using JWKS-fetched public keys.

  Uses joken_jwks to automatically fetch and cache Clerk's public signing keys.
  Validates: signature (RS256 via JWKS), expiry, not-before, issuer.
  """

  use Joken.Config

  add_hook(JokenJwks, strategy: Engram.Auth.ClerkStrategy)

  @impl true
  def token_config do
    default_claims(skip: [:aud, :jti, :iss])
    |> add_claim("iss", nil, &validate_issuer/1)
  end

  defp validate_issuer(issuer) do
    expected = Application.get_env(:engram, :clerk_issuer)
    issuer == expected
  end

  @doc """
  Verifies a Clerk JWT and returns `{:ok, claims}` or `{:error, reason}`.
  """
  def verify_clerk_jwt(token) do
    verify_and_validate(token)
  rescue
    _ -> {:error, :invalid_token}
  end
end
