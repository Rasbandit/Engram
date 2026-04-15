defmodule Engram.Auth.TokenResolver do
  @moduledoc """
  Shared token→user resolution used by both the Auth plug and UserSocket.

  Handles two auth methods:
    1. API key  — `engram_` prefix (always available)
    2. JWT      — delegates to the configured auth provider

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
    case Engram.Auth.provider().verify_token(token) do
      {:ok, %{external_id: ext_id, email: email}} ->
        Accounts.find_or_create_by_external_id(ext_id, %{email: email})

      {:error, _} = err ->
        err
    end
  end

  def resolve(_), do: {:error, :invalid_token}
end
