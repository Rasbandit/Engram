defmodule Engram.Crypto.KeyProvider.Resolver do
  @moduledoc """
  Returns the configured KeyProvider module. v1 uses compile-time/runtime
  config; future BYOK will look up per-user from users.key_provider column.
  """

  @spec provider() :: module()
  def provider do
    Application.get_env(:engram, :key_provider, Engram.Crypto.KeyProvider.Local)
  end

  @spec provider_for(user_id :: integer()) :: module()
  def provider_for(_user_id), do: provider()
end
