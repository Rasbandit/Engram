defmodule Engram.Crypto.QdrantPayloadTest do
  use Engram.DataCase, async: false
  alias Engram.Crypto
  alias Engram.Crypto.DekCache
  alias Engram.Vaults.Vault

  setup do
    DekCache.invalidate_all()
    user = insert(:user)
    {:ok, user: user}
  end

  @base_payload %{
    user_id: "1",
    vault_id: "5",
    source_path: "journal/today.md",
    folder: "journal",
    tags: ["personal"],
    chunk_index: 0,
    text: "dear diary",
    title: "today",
    heading_path: "intro"
  }

  describe "maybe_encrypt_qdrant_payload/3" do
    test "passes through when vault is not encrypted", %{user: user} do
      {:ok, user} = Crypto.ensure_user_dek(user)
      vault = %Vault{encrypted: false}

      assert {:ok, out} = Crypto.maybe_encrypt_qdrant_payload(@base_payload, user, vault)
      assert out == @base_payload
    end

    test "encrypts text/title/heading_path when vault is encrypted", %{user: user} do
      {:ok, user} = Crypto.ensure_user_dek(user)
      vault = %Vault{encrypted: true}

      assert {:ok, out} = Crypto.maybe_encrypt_qdrant_payload(@base_payload, user, vault)

      # Plaintext fields untouched
      assert out.user_id == "1"
      assert out.vault_id == "5"
      assert out.source_path == "journal/today.md"
      assert out.folder == "journal"
      assert out.tags == ["personal"]
      assert out.chunk_index == 0

      # Encrypted fields are base64 strings, different from plaintext
      assert is_binary(out.text)
      assert is_binary(out.title)
      assert is_binary(out.heading_path)
      refute out.text == "dear diary"
      refute out.title == "today"
      refute out.heading_path == "intro"

      # Nonces present, base64, 12 bytes decoded
      assert is_binary(out.text_nonce)
      assert byte_size(Base.decode64!(out.text_nonce)) == 12
      assert byte_size(Base.decode64!(out.title_nonce)) == 12
      assert byte_size(Base.decode64!(out.heading_path_nonce)) == 12
    end

    test "produces distinct nonces across calls", %{user: user} do
      {:ok, user} = Crypto.ensure_user_dek(user)
      vault = %Vault{encrypted: true}

      {:ok, o1} = Crypto.maybe_encrypt_qdrant_payload(@base_payload, user, vault)
      {:ok, o2} = Crypto.maybe_encrypt_qdrant_payload(@base_payload, user, vault)

      refute o1.text_nonce == o2.text_nonce
      refute o1.text == o2.text
    end

    test "returns {:error, :no_dek} when user lacks a DEK on encrypted vault", %{user: user} do
      # No ensure_user_dek — user.encrypted_dek stays nil
      vault = %Vault{encrypted: true}
      assert {:error, :no_dek} = Crypto.maybe_encrypt_qdrant_payload(@base_payload, user, vault)
    end

    test "encrypts empty strings deterministically-shaped", %{user: user} do
      {:ok, user} = Crypto.ensure_user_dek(user)
      vault = %Vault{encrypted: true}
      payload = %{@base_payload | text: "", title: "", heading_path: ""}

      assert {:ok, out} = Crypto.maybe_encrypt_qdrant_payload(payload, user, vault)
      # Empty plaintext still produces 16-byte GCM tag → non-empty b64 ciphertext
      assert byte_size(Base.decode64!(out.text)) == 16
    end
  end
end
