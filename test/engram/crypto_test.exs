defmodule Engram.CryptoTest do
  use Engram.DataCase, async: false
  alias Engram.Crypto
  alias Engram.Crypto.DekCache

  setup do
    DekCache.invalidate_all()
    user = insert(:user)
    {:ok, user: user}
  end

  test "ensure_user_dek provisions a DEK once", %{user: user} do
    {:ok, user1} = Crypto.ensure_user_dek(user)
    assert is_binary(user1.encrypted_dek)
    assert user1.dek_version == 1
    assert user1.key_provider == "local"

    # Idempotent: calling again returns the same wrapped DEK
    {:ok, user2} = Crypto.ensure_user_dek(user1)
    assert user2.encrypted_dek == user1.encrypted_dek
  end

  test "get_dek caches after first unwrap", %{user: user} do
    {:ok, user} = Crypto.ensure_user_dek(user)
    # ensure_user_dek pre-populates the cache; clear it to exercise the unwrap path.
    DekCache.invalidate(user.id)
    assert :miss = DekCache.get(user.id)

    {:ok, dek} = Crypto.get_dek(user)
    assert byte_size(dek) == 32
    assert {:ok, ^dek} = DekCache.get(user.id)
  end

  test "get_dek returns error if no DEK provisioned", %{user: user} do
    assert {:error, :no_dek} = Crypto.get_dek(user)
  end
end
