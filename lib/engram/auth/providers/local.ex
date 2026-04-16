defmodule Engram.Auth.Providers.Local do
  @moduledoc """
  Local auth provider — built-in email/password authentication.
  Issues HS256 JWTs for access tokens. Used by self-hosted deployments.
  """

  @behaviour Engram.Auth.Provider

  @access_token_ttl 15 * 60

  @impl true
  def verify_token(token) do
    case Engram.Token.verify_and_validate(token) do
      {:ok, claims} ->
        case {claims["sub"], claims["email"]} do
          {ext_id, email} when is_binary(ext_id) and is_binary(email) and email != "" ->
            {:ok, %{external_id: ext_id, email: email}}

          _ ->
            {:error, :missing_claims}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def authenticate_credentials(email, password) do
    case Engram.Accounts.verify_password(email, password) do
      {:ok, user} -> {:ok, %{external_id: user.external_id, email: user.email}}
      {:error, _} = err -> err
    end
  end

  @impl true
  def register_user(email, password, _opts) do
    case Engram.Accounts.create_user_with_password(email, password) do
      {:ok, user} -> {:ok, %{external_id: user.external_id, email: user.email}}
      {:error, :password_too_short} -> {:error, :password_too_short}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @impl true
  def supports_credentials?, do: true

  @impl true
  def resolve_user(external_id, _email) do
    Engram.Accounts.find_by_external_id(external_id)
  end

  @doc "Issues a short-lived HS256 access token with sub, email, iss, and aud claims."
  def issue_access_token(external_id, email) do
    claims = %{
      "sub" => external_id,
      "email" => email,
      "exp" => :os.system_time(:second) + @access_token_ttl,
      "iss" => "engram",
      "aud" => "engram"
    }

    case Engram.Token.generate_and_sign(claims) do
      {:ok, token, _claims} -> {:ok, token}
      {:error, reason} -> {:error, reason}
    end
  end
end
