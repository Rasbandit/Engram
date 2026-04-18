defmodule Engram.Crypto.QdrantPayloadTest do
  use Engram.DataCase, async: false
  import Bitwise, only: [bxor: 2]
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

  describe "maybe_decrypt_qdrant_candidates/3" do
    setup %{user: user} do
      {:ok, user} = Crypto.ensure_user_dek(user)
      enc_vault = %Vault{id: 5, encrypted: true}
      plain_vault = %Vault{id: 7, encrypted: false}

      # Build one encrypted candidate
      {:ok, enc_payload} =
        Crypto.maybe_encrypt_qdrant_payload(
          %{text: "secret", title: "T", heading_path: "intro"},
          user,
          enc_vault
        )

      enc_candidate = %{
        score: 0.9,
        qdrant_id: "qid-1",
        vault_id: "5",
        source_path: "a.md",
        tags: [],
        text: enc_payload.text,
        title: enc_payload.title,
        heading_path: enc_payload.heading_path,
        text_nonce: enc_payload.text_nonce,
        title_nonce: enc_payload.title_nonce,
        heading_path_nonce: enc_payload.heading_path_nonce
      }

      plain_candidate = %{
        score: 0.8,
        qdrant_id: "qid-2",
        vault_id: "7",
        source_path: "b.md",
        tags: [],
        text: "plain",
        title: "P",
        heading_path: "root"
      }

      vaults_by_id = %{"5" => enc_vault, "7" => plain_vault}

      {:ok,
       user: user,
       enc_candidate: enc_candidate,
       plain_candidate: plain_candidate,
       vaults_by_id: vaults_by_id}
    end

    test "round-trips encrypted candidates to plaintext", %{
      user: user,
      enc_candidate: enc,
      vaults_by_id: vaults
    } do
      assert {:ok, [out]} = Crypto.maybe_decrypt_qdrant_candidates([enc], user, vaults)
      assert out.text == "secret"
      assert out.title == "T"
      assert out.heading_path == "intro"
      refute Map.has_key?(out, :text_nonce)
    end

    test "passes through unencrypted candidates byte-exact", %{
      user: user,
      plain_candidate: pc,
      vaults_by_id: vaults
    } do
      assert {:ok, [out]} = Crypto.maybe_decrypt_qdrant_candidates([pc], user, vaults)
      assert out == pc
    end

    test "handles mixed list", %{
      user: user,
      enc_candidate: enc,
      plain_candidate: pc,
      vaults_by_id: vaults
    } do
      assert {:ok, [a, b]} = Crypto.maybe_decrypt_qdrant_candidates([enc, pc], user, vaults)
      assert a.text == "secret"
      assert b.text == "plain"
    end

    test "drops tampered candidate, keeps others, emits telemetry + error log", %{
      user: user,
      enc_candidate: enc,
      plain_candidate: pc,
      vaults_by_id: vaults
    } do
      # Tamper: flip one bit of the base64-decoded ciphertext, re-encode
      <<first, rest::binary>> = Base.decode64!(enc.text)
      tampered_ct = Base.encode64(<<bxor(first, 1), rest::binary>>)
      tampered = %{enc | text: tampered_ct}

      handler_id = {__MODULE__, :decrypt_failed_handler, System.unique_integer()}
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:engram, :search, :decrypt_failed],
        fn _event, measurements, meta, _ ->
          send(test_pid, {:telemetry_fired, measurements, meta})
        end,
        nil
      )

      try do
        log =
          ExUnit.CaptureLog.capture_log(fn ->
            assert {:ok, [out]} =
                     Crypto.maybe_decrypt_qdrant_candidates([tampered, pc], user, vaults)

            # Only the plaintext candidate survives
            assert out.qdrant_id == "qid-2"
          end)

        assert log =~ "decrypt"
        assert_received {:telemetry_fired, %{count: 1}, %{qdrant_id: "qid-1"}}
      after
        :telemetry.detach(handler_id)
      end
    end

    test "returns :decrypt_failed when ALL candidates fail", %{
      user: user,
      enc_candidate: enc,
      vaults_by_id: vaults
    } do
      <<first, rest::binary>> = Base.decode64!(enc.text)
      tampered_ct = Base.encode64(<<bxor(first, 1), rest::binary>>)
      tampered = %{enc | text: tampered_ct}

      assert {:error, :decrypt_failed} =
               Crypto.maybe_decrypt_qdrant_candidates([tampered], user, vaults)
    end

    test "empty input returns {:ok, []}", %{user: user, vaults_by_id: vaults} do
      assert {:ok, []} = Crypto.maybe_decrypt_qdrant_candidates([], user, vaults)
    end

    test "drops candidate when vault_id-to-vault map is missing an entry", %{
      user: user,
      enc_candidate: enc
    } do
      # Vault 5 not in map → shape-mismatch guard
      empty = %{}

      handler_id = {__MODULE__, :shape_mismatch_handler, System.unique_integer()}
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:engram, :search, :payload_shape_mismatch],
        fn _e, m, meta, _ -> send(test_pid, {:shape_mismatch, m, meta}) end,
        nil
      )

      try do
        assert {:error, :decrypt_failed} =
                 Crypto.maybe_decrypt_qdrant_candidates([enc], user, empty)

        assert_received {:shape_mismatch, _, _}
      after
        :telemetry.detach(handler_id)
      end
    end

    test "drops candidate with text_nonce but no vault_id (shape mismatch)", %{user: user} do
      # Legacy candidate missing vault_id but carrying ciphertext — impossible via
      # the normal index path (Phase 4 always writes vault_id), but defensive.
      broken = %{
        score: 0.5,
        qdrant_id: "qid-broken",
        source_path: "x.md",
        tags: [],
        text: "dGVzdA==",
        title: "dA==",
        heading_path: "aA==",
        text_nonce: "bm9uY2Vfbm9uY2VfMTI=",
        title_nonce: "bm9uY2Vfbm9uY2VfMTI=",
        heading_path_nonce: "bm9uY2Vfbm9uY2VfMTI="
      }

      handler_id = {__MODULE__, :missing_vault_id_handler, System.unique_integer()}
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:engram, :search, :payload_shape_mismatch],
        fn _e, m, meta, _ -> send(test_pid, {:shape_mismatch, m, meta}) end,
        nil
      )

      try do
        assert {:error, :decrypt_failed} =
                 Crypto.maybe_decrypt_qdrant_candidates([broken], user, %{})

        assert_received {:shape_mismatch, %{count: 1}, %{qdrant_id: "qid-broken"}}
      after
        :telemetry.detach(handler_id)
      end
    end

    test "returns :decrypt_failed and logs when encrypted candidate + user has no DEK" do
      # User without ensure_user_dek — encrypted_dek stays nil → get_dek returns {:error, :no_dek}
      user = insert(:user)
      vault = %Vault{id: 5, encrypted: true}

      candidate = %{
        score: 0.9,
        qdrant_id: "qid-x",
        vault_id: "5",
        source_path: "a.md",
        tags: [],
        text: "dGVzdA==",
        title: "dA==",
        heading_path: "aA==",
        text_nonce: "bm9uY2Vfbm9uY2VfMTI=",
        title_nonce: "bm9uY2Vfbm9uY2VfMTI=",
        heading_path_nonce: "bm9uY2Vfbm9uY2VfMTI="
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :decrypt_failed} =
                   Crypto.maybe_decrypt_qdrant_candidates([candidate], user, %{"5" => vault})
        end)

      assert log =~ "failed to load DEK"
      assert log =~ "user_id=#{user.id}"
    end
  end
end
