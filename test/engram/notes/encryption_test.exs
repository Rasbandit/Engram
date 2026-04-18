defmodule Engram.Notes.EncryptionTest do
  use Engram.DataCase, async: false

  alias Engram.Crypto.DekCache
  alias Engram.Notes

  # DekCache is a global GenServer; must be synchronous and flushed between tests.
  setup do
    DekCache.invalidate_all()
    :ok
  end

  describe "encrypted vault round-trip" do
    test "upsert then read returns plaintext, DB columns hold ciphertext" do
      user = insert(:user)
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)
      vault = insert(:vault, user: user, encrypted: true)

      {:ok, _note} =
        Notes.upsert_note(user, vault, %{
          "path" => "journal/today.md",
          "content" => "dear diary, I feel seen",
          "mtime" => 1_000.0
        })

      # Public read path decrypts and returns plaintext
      {:ok, note} = Notes.get_note(user, vault, "journal/today.md")
      assert note.content == "dear diary, I feel seen"

      # Raw DB: plaintext content is replaced by empty string (default_content guard),
      # title is nil, ciphertext columns are populated, nonce is 12 bytes,
      # and the ciphertext bytes do NOT equal the plaintext string.
      {:ok, raw} =
        Engram.Repo.with_tenant(user.id, fn ->
          Engram.Repo.get_by!(Engram.Notes.Note, path: "journal/today.md", user_id: user.id)
        end)

      # content is cleared (coerced to "" by the changeset default_content guard)
      assert raw.content == ""
      # title is nil (no default coercion)
      assert raw.title == nil
      # ciphertext columns are populated
      assert is_binary(raw.content_ciphertext)
      assert byte_size(raw.content_ciphertext) > 0
      # nonce is exactly 12 bytes (AES-256-GCM standard)
      assert byte_size(raw.content_nonce) == 12
      # ciphertext does not equal the original plaintext bytes
      refute raw.content_ciphertext == "dear diary, I feel seen"
    end

    test "unencrypted vault stores plaintext unchanged, ciphertext is nil" do
      user = insert(:user)
      vault = insert(:vault, user: user, encrypted: false)

      {:ok, _note} =
        Notes.upsert_note(user, vault, %{
          "path" => "recipes/chicken.md",
          "content" => "400F for 25min",
          "mtime" => 1_000.0
        })

      {:ok, raw} =
        Engram.Repo.with_tenant(user.id, fn ->
          Engram.Repo.get_by!(Engram.Notes.Note, path: "recipes/chicken.md", user_id: user.id)
        end)

      assert raw.content == "400F for 25min"
      assert raw.content_ciphertext == nil
    end
  end
end
