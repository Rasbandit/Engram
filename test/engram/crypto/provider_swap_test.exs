defmodule Engram.Crypto.ProviderSwapTest do
  @moduledoc """
  Verifies provider-swap safety: wrapping blobs from one master key are
  unreadable under a different master key. The error surfaces as a clean
  {:error, _} (not a crash or silent corruption). Operators must migrate
  data explicitly before swapping keys in production.
  """

  use Engram.DataCase, async: false

  alias Engram.Crypto
  alias Engram.Crypto.DekCache

  setup do
    DekCache.invalidate_all()
    orig_key = Application.get_env(:engram, :encryption_master_key)

    on_exit(fn ->
      Application.put_env(:engram, :encryption_master_key, orig_key)
      Application.delete_env(:engram, :encryption_master_key_previous)
    end)

    :ok
  end

  test "unwrap fails cleanly after master key swap" do
    key_a = Base.encode64(:crypto.strong_rand_bytes(32))
    key_b = Base.encode64(:crypto.strong_rand_bytes(32))

    # Provision a DEK wrapped under key A
    Application.put_env(:engram, :encryption_master_key, key_a)
    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    DekCache.invalidate(user.id)

    # Swap to key B — no ENCRYPTION_MASTER_KEY_PREVIOUS, so no fallback
    Application.put_env(:engram, :encryption_master_key, key_b)
    Application.delete_env(:engram, :encryption_master_key_previous)

    # Must fail cleanly — no crash, no garbage returned
    assert {:error, _reason} = Crypto.get_dek(user)
  end

  test "unwrap succeeds during rotation window (previous key set)" do
    key_a = Base.encode64(:crypto.strong_rand_bytes(32))
    key_b = Base.encode64(:crypto.strong_rand_bytes(32))

    # Provision a DEK wrapped under key A
    Application.put_env(:engram, :encryption_master_key, key_a)
    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    DekCache.invalidate(user.id)

    # Rotation: current = B, previous = A (just swapped — fallback is available)
    Application.put_env(:engram, :encryption_master_key, key_b)
    Application.put_env(:engram, :encryption_master_key_previous, key_a)

    assert {:ok, dek} = Crypto.get_dek(user)
    assert byte_size(dek) == 32
  end
end
