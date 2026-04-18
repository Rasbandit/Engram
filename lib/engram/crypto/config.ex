defmodule Engram.Crypto.Config do
  @moduledoc """
  Validates encryption configuration at application boot.
  Raises with actionable messages if misconfigured.
  """

  @valid_providers [
    Engram.Crypto.KeyProvider.Local
    # Future: Engram.Crypto.KeyProvider.AwsKms, Engram.Crypto.KeyProvider.Passphrase
  ]

  @spec validate!() :: :ok
  def validate! do
    provider = Application.get_env(:engram, :key_provider)

    unless provider in @valid_providers do
      raise "unknown key_provider #{inspect(provider)}; valid options: #{inspect(@valid_providers)}"
    end

    if provider == Engram.Crypto.KeyProvider.Local do
      validate_local_master_key!()
    end

    :ok
  end

  @doc "Returns the decoded 32-byte master key for the Local provider."
  @spec local_master_key!() :: <<_::256>>
  def local_master_key! do
    raw = Application.get_env(:engram, :encryption_master_key)
    decode_master_key!(raw, "ENCRYPTION_MASTER_KEY")
  end

  @doc "Returns the decoded 32-byte previous master key if set, else nil. For rotation."
  @spec local_master_key_previous() :: <<_::256>> | nil
  def local_master_key_previous do
    case Application.get_env(:engram, :encryption_master_key_previous) do
      nil -> nil
      "" -> nil
      raw -> decode_master_key!(raw, "ENCRYPTION_MASTER_KEY_PREVIOUS")
    end
  end

  defp validate_local_master_key! do
    _ = local_master_key!()
    :ok
  end

  defp decode_master_key!(nil, name), do: raise("#{name} is required when KEY_PROVIDER=local")
  defp decode_master_key!("", name), do: raise("#{name} is required when KEY_PROVIDER=local")

  defp decode_master_key!(raw, name) when is_binary(raw) do
    case Base.decode64(raw) do
      {:ok, <<_::256>> = key} ->
        key

      {:ok, other} ->
        raise "#{name} must decode to 32 bytes; got #{byte_size(other)} bytes"

      :error ->
        raise "#{name} must be valid base64"
    end
  end
end
