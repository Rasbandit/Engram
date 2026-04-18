defmodule Engram.Crypto.KeyProvider.Local do
  @moduledoc """
  KeyProvider implementation backed by an env-var master key.
  Wraps DEKs with AES-256-GCM using ENCRYPTION_MASTER_KEY.
  Supports one-key-back fallback for rotation via ENCRYPTION_MASTER_KEY_PREVIOUS.
  """

  @behaviour Engram.Crypto.KeyProvider

  alias Engram.Crypto.Envelope
  alias Engram.Crypto.Config

  @impl true
  def name, do: :local

  @impl true
  def generate_dek, do: Engram.Crypto.KeyProvider.default_generate_dek()

  @impl true
  def wrap_dek(<<_::256>> = dek, _ctx) do
    master = Config.local_master_key!()
    {ct, nonce} = Envelope.encrypt(dek, master)
    {:ok, <<nonce::binary-size(12), ct::binary>>}
  end

  @impl true
  def unwrap_dek(<<nonce::binary-size(12), ct::binary>>, _ctx) do
    current = Config.local_master_key!()

    case Envelope.decrypt(ct, nonce, current) do
      {:ok, <<_::256>> = dek} ->
        {:ok, dek}

      :error ->
        case Config.local_master_key_previous() do
          nil ->
            {:error, :invalid_wrapping}

          prev ->
            case Envelope.decrypt(ct, nonce, prev) do
              {:ok, <<_::256>> = dek} -> {:ok, dek}
              :error -> {:error, :invalid_wrapping}
            end
        end
    end
  end

  def unwrap_dek(_other, _ctx), do: {:error, :malformed_wrapped_blob}

  @impl true
  def supports_async_workers?, do: true

  @impl true
  def rotate_wrapping(wrapped, ctx) do
    with {:ok, dek} <- unwrap_dek(wrapped, ctx) do
      wrap_dek(dek, ctx)
    end
  end
end
