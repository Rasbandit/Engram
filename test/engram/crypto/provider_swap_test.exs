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
    orig_version = Application.get_env(:engram, :encryption_master_key_version)

    on_exit(fn ->
      Application.put_env(:engram, :encryption_master_key, orig_key)
      Application.delete_env(:engram, :encryption_master_key_previous)

      if orig_version do
        Application.put_env(:engram, :encryption_master_key_version, orig_version)
      else
        Application.delete_env(:engram, :encryption_master_key_version)
      end
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

  test "unwrap succeeds during rotation window (previous key set, master_key_version bumped)" do
    key_a = Base.encode64(:crypto.strong_rand_bytes(32))
    key_b = Base.encode64(:crypto.strong_rand_bytes(32))

    # Provision a DEK wrapped under key A. User starts at dek_version=1.
    Application.put_env(:engram, :encryption_master_key, key_a)
    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    DekCache.invalidate(user.id)

    # Rotation window: operator advances master_key_version to 2 BEFORE running
    # `rotate_all/1`, so users still at dek_version=1 (< 2) trigger the
    # `_PREVIOUS` fallback gate's allow path. Without bumping the version, M4
    # treats the user as already-rotated and refuses fallback.
    Application.put_env(:engram, :encryption_master_key, key_b)
    Application.put_env(:engram, :encryption_master_key_previous, key_a)
    Application.put_env(:engram, :encryption_master_key_version, 2)

    assert {:ok, dek} = Crypto.get_dek(user)
    assert byte_size(dek) == 32
  end

  test "unwrap fails (gated by dek_version) when operator forgets to bump master_key_version" do
    # M4 — refuses to use _PREVIOUS for a user whose dek_version is at or
    # above the configured master_key_version. This is the exact misconfig
    # we want to surface: PREVIOUS set but VERSION not bumped means the
    # operator is in an inconsistent state and silent fallback would mask it.
    key_a = Base.encode64(:crypto.strong_rand_bytes(32))
    key_b = Base.encode64(:crypto.strong_rand_bytes(32))

    Application.put_env(:engram, :encryption_master_key, key_a)
    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    DekCache.invalidate(user.id)

    Application.put_env(:engram, :encryption_master_key, key_b)
    Application.put_env(:engram, :encryption_master_key_previous, key_a)
    Application.delete_env(:engram, :encryption_master_key_version)

    assert {:error, :invalid_wrapping} = Crypto.get_dek(user)
  end
end
