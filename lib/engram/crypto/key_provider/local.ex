defmodule Engram.Crypto.KeyProvider.Local do
  @moduledoc """
  KeyProvider implementation backed by an env-var master key.
  Wraps DEKs with AES-256-GCM using ENCRYPTION_MASTER_KEY.
  Supports one-key-back fallback for rotation via ENCRYPTION_MASTER_KEY_PREVIOUS.

  ## Wrap format (T3.4 / M2)

  New writes use a 2-byte header before nonce + ciphertext:

      <<0x01, 0x01, nonce::binary-size(12), ct::binary>>
      # ^^^   ^^^   ^^^^^^^^^^^^^^^^^^^^   ^^^^^^^^^^^
      #  |     |    |                       AES-GCM ct + 16-byte tag
      #  |     |    fresh per-encrypt nonce
      #  |     algorithm id (0x01 = AES-256-GCM)
      #  wrap-format version (0x01 = first header-bearing version)

  Pre-T3.4 rows in DB carry the legacy raw shape `<<nonce::12, ct::binary>>`
  (no header). `unwrap_dek/2` reads both shapes — the version-byte form
  matches first, and a 60-byte raw shape falls through to the legacy
  clause. Disambiguation is by total `byte_size/1`:

      legacy: 12 (nonce) + 32 (DEK) + 16 (GCM tag) = 60 bytes
      v1:      2 (header) + 60                     = 62 bytes
  """

  @behaviour Engram.Crypto.KeyProvider

  alias Engram.Crypto.Envelope
  alias Engram.Crypto.Config

  # T3.4 / M2 — wrap-format constants.
  @wrap_version_v1 0x01
  @alg_aes_256_gcm 0x01

  @impl true
  def name, do: :local

  @impl true
  def generate_dek, do: Engram.Crypto.KeyProvider.default_generate_dek()

  @impl true
  def wrap_dek(<<_::256>> = dek, _ctx) do
    master = Config.local_master_key!()
    {ct, nonce} = Envelope.encrypt(dek, master)

    {:ok,
     <<@wrap_version_v1, @alg_aes_256_gcm, nonce::binary-size(12), ct::binary>>}
  end

  @impl true
  def unwrap_dek(blob, ctx) when is_binary(blob) do
    case blob do
      <<@wrap_version_v1, @alg_aes_256_gcm, nonce::binary-size(12), ct::binary>>
      when byte_size(blob) == 62 ->
        do_unwrap(ct, nonce, ctx)

      <<nonce::binary-size(12), ct::binary>> when byte_size(blob) == 60 ->
        # T3.4 — legacy pre-header shape. Kept for backward read so the
        # wrap-version rollout does not require a backfill pass.
        do_unwrap(ct, nonce, ctx)

      _ ->
        {:error, :malformed_wrapped_blob}
    end
  end

  def unwrap_dek(_other, _ctx), do: {:error, :malformed_wrapped_blob}

  # T3.5 / M4 — `_PREVIOUS` fallback is gated on the user's `dek_version`
  # vs the configured `master_key_version`. A user whose dek_version is
  # at-or-above the current master generation has been rotated already;
  # if its blob fails to decrypt with the current key, that is a real
  # error — falling through to `_PREVIOUS` would silently mask a wrong-
  # key boot or a rotation regression.
  #
  # Telemetry `[:engram, :crypto, :previous_fallback_hit]` fires
  # whenever the fallback is consulted (whether it rescues or not), so
  # operators can watch the count drop to zero post-rotation.
  defp do_unwrap(ct, nonce, ctx) do
    current = Config.local_master_key!()

    case Envelope.decrypt(ct, nonce, current) do
      {:ok, <<_::256>> = dek} ->
        {:ok, dek}

      :error ->
        try_previous_fallback(ct, nonce, ctx)
    end
  end

  defp try_previous_fallback(ct, nonce, ctx) do
    if previous_fallback_allowed?(ctx) do
      case Config.local_master_key_previous() do
        nil ->
          emit_fallback_telemetry(ctx, :no_previous_configured)
          {:error, :invalid_wrapping}

        prev ->
          result =
            case Envelope.decrypt(ct, nonce, prev) do
              {:ok, <<_::256>> = dek} -> {:ok, dek}
              :error -> {:error, :invalid_wrapping}
            end

          emit_fallback_telemetry(ctx, result)
          result
      end
    else
      emit_fallback_telemetry(ctx, :gated_by_dek_version)
      {:error, :invalid_wrapping}
    end
  end

  defp previous_fallback_allowed?(ctx) do
    cond do
      Map.get(ctx, :disable_previous_fallback) == true ->
        false

      true ->
        dek_version = Map.get(ctx, :dek_version)
        master_key_version = Map.get(ctx, :master_key_version) || Config.master_key_version()

        is_nil(dek_version) or dek_version < master_key_version
    end
  end

  defp emit_fallback_telemetry(ctx, outcome) do
    :telemetry.execute(
      [:engram, :crypto, :previous_fallback_hit],
      %{count: 1},
      %{
        user_id: Map.get(ctx, :user_id),
        dek_version: Map.get(ctx, :dek_version),
        master_key_version:
          Map.get(ctx, :master_key_version) || Config.master_key_version(),
        outcome: classify_outcome(outcome)
      }
    )
  end

  defp classify_outcome({:ok, _}), do: :rescued
  defp classify_outcome({:error, :invalid_wrapping}), do: :failed
  defp classify_outcome(:no_previous_configured), do: :no_previous_configured
  defp classify_outcome(:gated_by_dek_version), do: :gated_by_dek_version

  @impl true
  def supports_async_workers?, do: true

  @impl true
  def rotate_wrapping(wrapped, ctx) do
    with {:ok, dek} <- unwrap_dek(wrapped, ctx) do
      wrap_dek(dek, ctx)
    end
  end

  @doc """
  T3.5.5 / M3 — current-master-key-only unwrap, for `BootCanary`. Bypasses
  `_PREVIOUS` fallback so a misconfigured `ENCRYPTION_MASTER_KEY` cannot
  be silently rescued by `_PREVIOUS` during boot verification. Distinct
  from `unwrap_dek/2` so production callers cannot accidentally adopt
  this mode and break legitimate rotation reads.
  """
  @spec unwrap_dek_current_only(binary()) :: {:ok, <<_::256>>} | {:error, term()}
  def unwrap_dek_current_only(blob) when is_binary(blob) do
    current = Config.local_master_key!()

    case blob do
      <<@wrap_version_v1, @alg_aes_256_gcm, nonce::binary-size(12), ct::binary>>
      when byte_size(blob) == 62 ->
        decrypt_or_invalid(ct, nonce, current)

      <<nonce::binary-size(12), ct::binary>> when byte_size(blob) == 60 ->
        decrypt_or_invalid(ct, nonce, current)

      _ ->
        {:error, :malformed_wrapped_blob}
    end
  end

  defp decrypt_or_invalid(ct, nonce, key) do
    case Envelope.decrypt(ct, nonce, key) do
      {:ok, <<_::256>> = dek} -> {:ok, dek}
      :error -> {:error, :invalid_wrapping}
    end
  end
end
