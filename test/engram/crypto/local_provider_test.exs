defmodule Engram.Crypto.KeyProvider.LocalTest do
  use ExUnit.Case, async: false
  alias Engram.Crypto.KeyProvider.Local

  setup do
    key = :crypto.strong_rand_bytes(32)
    Application.put_env(:engram, :encryption_master_key, Base.encode64(key))
    on_exit(fn -> Application.delete_env(:engram, :encryption_master_key_previous) end)
    {:ok, key: key}
  end

  test "name/0" do
    assert Local.name() == :local
  end

  test "generate_dek returns 32 bytes" do
    assert byte_size(Local.generate_dek()) == 32
  end

  test "wrap/unwrap round-trips" do
    dek = Local.generate_dek()
    {:ok, wrapped} = Local.wrap_dek(dek, %{user_id: 1})
    assert {:ok, ^dek} = Local.unwrap_dek(wrapped, %{user_id: 1})
  end

  test "wrap produces distinct blobs for same DEK" do
    dek = Local.generate_dek()
    {:ok, w1} = Local.wrap_dek(dek, %{user_id: 1})
    {:ok, w2} = Local.wrap_dek(dek, %{user_id: 1})
    refute w1 == w2
  end

  test "unwrap fails on tampered blob" do
    dek = Local.generate_dek()
    {:ok, <<first, rest::binary>>} = Local.wrap_dek(dek, %{user_id: 1})
    tampered = <<Bitwise.bxor(first, 1), rest::binary>>
    assert {:error, _} = Local.unwrap_dek(tampered, %{user_id: 1})
  end

  test "unwrap falls back to previous key during rotation" do
    old_key = :crypto.strong_rand_bytes(32)
    new_key = :crypto.strong_rand_bytes(32)

    Application.put_env(:engram, :encryption_master_key, Base.encode64(old_key))
    dek = Local.generate_dek()
    {:ok, wrapped_with_old} = Local.wrap_dek(dek, %{user_id: 1})

    Application.put_env(:engram, :encryption_master_key, Base.encode64(new_key))
    Application.put_env(:engram, :encryption_master_key_previous, Base.encode64(old_key))

    assert {:ok, ^dek} = Local.unwrap_dek(wrapped_with_old, %{user_id: 1})
  end

  test "supports_async_workers? returns true" do
    assert Local.supports_async_workers?() == true
  end

  test "rotate_wrapping re-wraps with current key" do
    dek = Local.generate_dek()
    {:ok, old_wrapped} = Local.wrap_dek(dek, %{user_id: 1})
    {:ok, new_wrapped} = Local.rotate_wrapping(old_wrapped, %{user_id: 1})
    refute old_wrapped == new_wrapped
    assert {:ok, ^dek} = Local.unwrap_dek(new_wrapped, %{user_id: 1})
  end
end
