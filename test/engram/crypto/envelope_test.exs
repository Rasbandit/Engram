defmodule Engram.Crypto.EnvelopeTest do
  use ExUnit.Case, async: true
  alias Engram.Crypto.Envelope

  @dek :crypto.strong_rand_bytes(32)

  test "round-trips plaintext" do
    {ct, nonce} = Envelope.encrypt("hello world", @dek)
    assert {:ok, "hello world"} = Envelope.decrypt(ct, nonce, @dek)
  end

  test "produces unique nonces" do
    {_, n1} = Envelope.encrypt("x", @dek)
    {_, n2} = Envelope.encrypt("x", @dek)
    refute n1 == n2
    assert byte_size(n1) == 12
  end

  test "rejects tampered ciphertext" do
    {ct, nonce} = Envelope.encrypt("secret", @dek)
    <<first, rest::binary>> = ct
    tampered = <<Bitwise.bxor(first, 1), rest::binary>>
    assert :error = Envelope.decrypt(tampered, nonce, @dek)
  end

  test "rejects wrong key" do
    {ct, nonce} = Envelope.encrypt("secret", @dek)
    other_key = :crypto.strong_rand_bytes(32)
    assert :error = Envelope.decrypt(ct, nonce, other_key)
  end

  test "handles empty plaintext" do
    {ct, nonce} = Envelope.encrypt("", @dek)
    assert {:ok, ""} = Envelope.decrypt(ct, nonce, @dek)
  end

  test "rejects malformed (wrong-length) nonce" do
    {ct, _nonce} = Envelope.encrypt("secret", @dek)
    short_nonce = :crypto.strong_rand_bytes(8)
    assert :error = Envelope.decrypt(ct, short_nonce, @dek)

    long_nonce = :crypto.strong_rand_bytes(16)
    assert :error = Envelope.decrypt(ct, long_nonce, @dek)
  end
end
