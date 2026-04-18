defmodule Engram.Crypto.DekCacheTest do
  use ExUnit.Case, async: false
  alias Engram.Crypto.DekCache

  setup do
    DekCache.invalidate_all()
    :ok
  end

  @dek :binary.copy(<<0xAA>>, 32)

  test "put + get round-trip" do
    DekCache.put(1, @dek)
    assert {:ok, @dek} = DekCache.get(1)
  end

  test "miss returns :miss" do
    assert :miss = DekCache.get(404)
  end

  test "invalidate removes entry" do
    DekCache.put(1, @dek)
    DekCache.invalidate(1)
    assert :miss = DekCache.get(1)
  end

  test "invalidate_all clears everything" do
    DekCache.put(1, @dek)
    DekCache.put(2, @dek)
    DekCache.invalidate_all()
    assert :miss = DekCache.get(1)
    assert :miss = DekCache.get(2)
  end

  test "entries expire after TTL" do
    DekCache.put(1, @dek, _ttl_ms = 10)
    Process.sleep(25)
    DekCache.sweep_now()
    assert :miss = DekCache.get(1)
  end
end
