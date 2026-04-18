defmodule Engram.Crypto do
  @moduledoc """
  Public API for encryption. Wraps the KeyProvider behaviour and DekCache.

  Lazy DEK provisioning: users get a DEK only when encryption is first needed.
  """

  alias Engram.Accounts
  alias Engram.Accounts.User
  alias Engram.Crypto.{DekCache, KeyProvider.Resolver}

  @doc """
  Ensures the user has a wrapped DEK stored. Idempotent — returns the user
  untouched if `encrypted_dek` is already present.
  """
  @spec ensure_user_dek(User.t()) :: {:ok, User.t()} | {:error, term()}
  def ensure_user_dek(%User{encrypted_dek: blob} = user) when is_binary(blob), do: {:ok, user}

  def ensure_user_dek(%User{} = user) do
    provider = Resolver.provider_for(user.id)
    dek = provider.generate_dek()

    with {:ok, wrapped} <- provider.wrap_dek(dek, %{user_id: user.id}),
         {:ok, user} <-
           Accounts.update_user_encryption(user, %{
             encrypted_dek: wrapped,
             dek_version: 1,
             key_provider: Atom.to_string(provider.name())
           }) do
      DekCache.put(user.id, dek)
      {:ok, user}
    end
  end

  @doc """
  Returns the plaintext DEK for a user, unwrapping via the provider if not cached.
  """
  @spec get_dek(User.t()) :: {:ok, <<_::256>>} | {:error, term()}
  def get_dek(%User{encrypted_dek: nil}), do: {:error, :no_dek}

  def get_dek(%User{id: user_id, encrypted_dek: blob}) do
    case DekCache.get(user_id) do
      {:ok, dek} ->
        {:ok, dek}

      :miss ->
        provider = Resolver.provider_for(user_id)

        case provider.unwrap_dek(blob, %{user_id: user_id}) do
          {:ok, dek} ->
            DekCache.put(user_id, dek)
            {:ok, dek}

          {:error, _} = err ->
            err
        end
    end
  end
end
