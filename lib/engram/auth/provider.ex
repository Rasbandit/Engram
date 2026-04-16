defmodule Engram.Auth.Provider do
  @moduledoc """
  Behaviour for pluggable auth providers.
  Implementations: Local (built-in), Clerk (SaaS).
  external_id is provider-specific: UUID for local users, Clerk user ID for Clerk.
  """

  @callback verify_token(token :: String.t()) ::
              {:ok, %{external_id: String.t(), email: String.t()}} | {:error, atom()}

  @callback authenticate_credentials(email :: String.t(), password :: String.t()) ::
              {:ok, %{external_id: String.t(), email: String.t()}} | {:error, atom()}

  @callback register_user(email :: String.t(), password :: String.t(), opts :: map()) ::
              {:ok, %{external_id: String.t(), email: String.t()}} | {:error, atom()}

  @callback supports_credentials?() :: boolean()

  @doc """
  Resolves a verified token's identity to a local user record.

  Clerk: JIT provisioning — creates or links user on first token presentation.
  Local: lookup only — user must already exist (created via /register).
  """
  @callback resolve_user(external_id :: String.t(), email :: String.t()) ::
              {:ok, Engram.Accounts.User.t()} | {:error, atom()}
end
