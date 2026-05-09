defmodule Engram.Crypto.UserDekRotationTest do
  use Engram.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Engram.Attachments
  alias Engram.Crypto
  alias Engram.Crypto.{DekCache, UserDekRotation}
  alias Engram.Repo

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture(dek_version: 1)
    {:ok, user: user}
  end

  describe "rotate_user/1 — lock handling" do
    test "returns {:error, :rotation_in_progress} when already locked", %{user: user} do
      Repo.update_all(
        from(u in Engram.Accounts.User, where: u.id == ^user.id),
        [set: [dek_rotation_locked_at: DateTime.utc_now()]],
        skip_tenant_check: true
      )

      assert {:error, :rotation_in_progress} = UserDekRotation.rotate_user(user.id)
    end

    test "returns {:error, :not_found} for missing user" do
      assert {:error, :not_found} = UserDekRotation.rotate_user(999_999_999)
    end
  end

  describe "rotate_user/1 — happy path with no ciphertext rows" do
    test "user with no notes/atts/vaults rotates cleanly", %{user: user} do
      old_wrapped = user.encrypted_dek
      assert :ok = UserDekRotation.rotate_user(user.id)

      refreshed = Repo.reload!(user)
      assert refreshed.dek_version == 2
      refute refreshed.encrypted_dek == old_wrapped
      assert is_nil(refreshed.dek_rotation_locked_at)
    end

    test "DekCache invalidated after flip", %{user: user} do
      DekCache.put(user.id, :crypto.strong_rand_bytes(32))
      assert {:ok, _stale_dek} = DekCache.get(user.id)

      assert :ok = UserDekRotation.rotate_user(user.id)

      assert :miss = DekCache.get(user.id)
    end
  end

  describe "rotate_user/1 — notes sweep" do
    setup %{user: user} do
      # Use insert_vault! so the vault has valid ciphertext (dek_version=1,
      # empty-AAD encrypted). The sweep will properly re-encrypt it alongside
      # the notes.
      vault = Engram.Fixtures.insert_vault!(user, "NotesSweepVault")

      note_a =
        Engram.Fixtures.insert_note!(user, vault, %{
          path: "alpha.md",
          content: "alpha content"
        })

      note_b =
        Engram.Fixtures.insert_note!(user, vault, %{
          path: "beta.md",
          content: "beta content"
        })

      {:ok, vault: vault, note_a: note_a, note_b: note_b}
    end

    test "every note re-encrypts under the new DEK", %{user: user, note_a: a, note_b: b} do
      assert :ok = UserDekRotation.rotate_user(user.id)

      reloaded_user =
        Repo.one!(from(u in Engram.Accounts.User, where: u.id == ^user.id), skip_tenant_check: true)

      reloaded_a =
        Repo.one!(from(n in Engram.Notes.Note, where: n.id == ^a.id), skip_tenant_check: true)

      reloaded_b =
        Repo.one!(from(n in Engram.Notes.Note, where: n.id == ^b.id), skip_tenant_check: true)

      assert reloaded_a.dek_version == 2
      assert reloaded_b.dek_version == 2

      assert {:ok, decrypted_a} = Crypto.maybe_decrypt_note_fields(reloaded_a, reloaded_user)
      assert decrypted_a.content == "alpha content"

      assert {:ok, decrypted_b} = Crypto.maybe_decrypt_note_fields(reloaded_b, reloaded_user)
      assert decrypted_b.content == "beta content"
    end

    test "ciphertext bytes change post-rotation", %{user: user, note_a: a} do
      old_ct = a.content_ciphertext
      assert :ok = UserDekRotation.rotate_user(user.id)

      reloaded =
        Repo.one!(from(n in Engram.Notes.Note, where: n.id == ^a.id), skip_tenant_check: true)

      refute reloaded.content_ciphertext == old_ct
    end
  end

  describe "rotate_user/1 — vaults sweep" do
    test "every vault re-encrypts under the new DEK", %{user: user} do
      vault = Engram.Fixtures.insert_vault!(user, "Personal")
      old_ct = vault.name_ciphertext

      assert :ok = UserDekRotation.rotate_user(user.id)

      reloaded_user =
        Repo.one!(from(u in Engram.Accounts.User, where: u.id == ^user.id), skip_tenant_check: true)

      reloaded_vault =
        Repo.one!(from(v in Engram.Vaults.Vault, where: v.id == ^vault.id), skip_tenant_check: true)

      assert reloaded_vault.dek_version == 2
      refute reloaded_vault.name_ciphertext == old_ct
      assert {:ok, decrypted} = Crypto.maybe_decrypt_vault_fields(reloaded_vault, reloaded_user)
      assert decrypted.name == "Personal"
    end
  end

  describe "rotate_user/1 — HMAC re-derivation" do
    setup %{user: user} do
      vault = Engram.Fixtures.insert_vault!(user, "Personal")

      note =
        Engram.Fixtures.insert_note!(user, vault, %{
          path: "alpha.md",
          content: "alpha",
          folder: "subfolder",
          tags: ["red", "blue"]
        })

      {:ok, vault: vault, note: note}
    end

    test "note path_hmac matches new filter_key after rotation", %{user: user, note: note} do
      assert :ok = UserDekRotation.rotate_user(user.id)

      reloaded_user =
        Repo.one!(from(u in Engram.Accounts.User, where: u.id == ^user.id), skip_tenant_check: true)

      reloaded_note =
        Repo.one!(from(n in Engram.Notes.Note, where: n.id == ^note.id), skip_tenant_check: true)

      {:ok, new_dek} = Crypto.get_dek(reloaded_user)
      new_filter_key = Crypto.dek_filter_key_from_bytes(new_dek)
      expected_path_hmac = Crypto.hmac_field(new_filter_key, "alpha.md")

      assert reloaded_note.path_hmac == expected_path_hmac
    end

    test "note folder_hmac matches new filter_key after rotation", %{user: user, note: note} do
      assert :ok = UserDekRotation.rotate_user(user.id)

      reloaded_user =
        Repo.one!(from(u in Engram.Accounts.User, where: u.id == ^user.id), skip_tenant_check: true)

      reloaded_note =
        Repo.one!(from(n in Engram.Notes.Note, where: n.id == ^note.id), skip_tenant_check: true)

      {:ok, new_dek} = Crypto.get_dek(reloaded_user)
      new_filter_key = Crypto.dek_filter_key_from_bytes(new_dek)
      expected_folder_hmac = Crypto.hmac_field(new_filter_key, "subfolder")

      assert reloaded_note.folder_hmac == expected_folder_hmac
    end

    test "note tags_hmac matches new filter_key after rotation", %{user: user, note: note} do
      assert :ok = UserDekRotation.rotate_user(user.id)

      reloaded_user =
        Repo.one!(from(u in Engram.Accounts.User, where: u.id == ^user.id), skip_tenant_check: true)

      reloaded_note =
        Repo.one!(from(n in Engram.Notes.Note, where: n.id == ^note.id), skip_tenant_check: true)

      {:ok, new_dek} = Crypto.get_dek(reloaded_user)
      new_filter_key = Crypto.dek_filter_key_from_bytes(new_dek)
      expected_red = Crypto.hmac_field(new_filter_key, "red")
      expected_blue = Crypto.hmac_field(new_filter_key, "blue")

      assert reloaded_note.tags_hmac == [expected_red, expected_blue]
    end

    test "vault name_hmac matches new filter_key after rotation", %{user: user, vault: vault} do
      assert :ok = UserDekRotation.rotate_user(user.id)

      reloaded_user =
        Repo.one!(from(u in Engram.Accounts.User, where: u.id == ^user.id), skip_tenant_check: true)

      reloaded_vault =
        Repo.one!(from(v in Engram.Vaults.Vault, where: v.id == ^vault.id), skip_tenant_check: true)

      {:ok, new_dek} = Crypto.get_dek(reloaded_user)
      new_filter_key = Crypto.dek_filter_key_from_bytes(new_dek)
      expected_name_hmac = Crypto.hmac_field(new_filter_key, "Personal")

      assert reloaded_vault.name_hmac == expected_name_hmac
    end

    test "note folder_hmac for empty folder is recomputed correctly", %{user: user, vault: vault} do
      note =
        Engram.Fixtures.insert_note!(user, vault, %{
          path: "rootlevel.md",
          content: "x",
          folder: ""
        })

      assert :ok = UserDekRotation.rotate_user(user.id)

      reloaded_user =
        Repo.one!(from(u in Engram.Accounts.User, where: u.id == ^user.id), skip_tenant_check: true)

      reloaded_note =
        Repo.one!(from(n in Engram.Notes.Note, where: n.id == ^note.id), skip_tenant_check: true)

      {:ok, new_dek} = Crypto.get_dek(reloaded_user)
      new_filter_key = Crypto.dek_filter_key_from_bytes(new_dek)
      expected = Crypto.hmac_field(new_filter_key, "")

      assert reloaded_note.folder_hmac == expected
    end
  end

  describe "rotate_user/1 — attachments sweep" do
    test "happy path: attachment blob re-encrypted under new DEK (legacy v1 fixture)", %{user: user} do
      vault = Engram.Fixtures.insert_vault!(user, "AttTest")

      # Use insert_attachment! to get a genuinely v1-encrypted (empty-AAD) row,
      # matching how insert_note! creates legacy fixtures for notes sweep tests.
      attachment =
        Engram.Fixtures.insert_attachment!(user, vault, %{
          path: "img.png",
          content: <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 1>>,
          mime_type: "image/png"
        })

      assert :ok = UserDekRotation.rotate_user(user.id)

      reloaded_user =
        Repo.one!(from(u in Engram.Accounts.User, where: u.id == ^user.id), skip_tenant_check: true)

      reloaded_att =
        Repo.one!(from(a in Engram.Attachments.Attachment, where: a.id == ^attachment.id),
          skip_tenant_check: true
        )

      assert reloaded_att.dek_version == 2
      assert is_nil(reloaded_att.dek_version_pending)

      # Round-trip the blob through the storage layer using the new DEK.
      {:ok, fetched} = Attachments.get_attachment(reloaded_user, vault, "img.png")
      assert fetched.content == <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 1>>
    end

    test "resume: attachment with dek_version_pending set is re-PUT and finalized", %{user: user} do
      vault = Engram.Fixtures.insert_vault!(user, "ResumeTest")

      attachment =
        Engram.Fixtures.insert_attachment!(user, vault, %{
          path: "doc.txt",
          content: "abcdef",
          mime_type: "text/plain"
        })

      # Simulate crash mid-rotation: pending set, dek_version still 1, S3 blob still under old DEK.
      Repo.update_all(
        from(a in Engram.Attachments.Attachment, where: a.id == ^attachment.id),
        [set: [dek_version_pending: 2]],
        skip_tenant_check: true
      )

      assert :ok = UserDekRotation.rotate_user(user.id)

      reloaded =
        Repo.one!(from(a in Engram.Attachments.Attachment, where: a.id == ^attachment.id),
          skip_tenant_check: true
        )

      assert reloaded.dek_version == 2
      assert is_nil(reloaded.dek_version_pending)
    end

    test "attachment path_hmac matches new filter_key after rotation", %{user: user} do
      vault = Engram.Fixtures.insert_vault!(user, "HmacTest")

      attachment =
        Engram.Fixtures.insert_attachment!(user, vault, %{
          path: "report.pdf",
          content: "hi",
          mime_type: "application/pdf"
        })

      assert :ok = UserDekRotation.rotate_user(user.id)

      reloaded_user =
        Repo.one!(from(u in Engram.Accounts.User, where: u.id == ^user.id), skip_tenant_check: true)

      reloaded_att =
        Repo.one!(from(a in Engram.Attachments.Attachment, where: a.id == ^attachment.id),
          skip_tenant_check: true
        )

      {:ok, new_dek} = Crypto.get_dek(reloaded_user)
      new_filter_key = Crypto.dek_filter_key_from_bytes(new_dek)
      expected = Crypto.hmac_field(new_filter_key, "report.pdf")

      assert reloaded_att.path_hmac == expected
    end
  end

  # ---------------------------------------------------------------------------
  # Production-path bug regression tests
  #
  # These exercise the real upsert paths (notes.ex/attachments.ex) which
  # hardcode `dek_version: Crypto.row_version_aad_bound()` (= 2). Before the
  # fix, the sweep cursor `WHERE dek_version < target` skipped these rows
  # entirely, leaving them encrypted under the old DEK after the final flip.
  # ---------------------------------------------------------------------------

  describe "rotate_user/1 — production-path bug regression" do
    setup %{user: user} do
      # Grant unlimited vaults so create_vault doesn't hit the billing limit.
      insert(:user_override, user: user, overrides: %{"max_vaults" => -1})
      {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "ProdVault"})
      {:ok, user: user, vault: vault}
    end

    test "rotation works for attachment created via real upsert (dek_version=2 hardcoded)", %{
      user: user,
      vault: vault
    } do
      content = <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 1>>

      {:ok, _att} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => "regression/img.png",
          "content_base64" => Base.encode64(content),
          "mime_type" => "image/png",
          "mtime" => 0.0
        })

      # Confirm the row was created at dek_version=2 (the production hardcode).
      raw =
        Repo.one!(
          from(a in Engram.Attachments.Attachment,
            where: a.user_id == ^user.id,
            where: not is_nil(a.deleted_at) or is_nil(a.deleted_at),
            order_by: [desc: a.id],
            limit: 1
          ),
          skip_tenant_check: true
        )

      assert raw.dek_version == 2,
             "Expected upsert_attachment to stamp dek_version=2, got #{raw.dek_version}"

      # Rotate the DEK — should NOT skip this row despite dek_version already == 2.
      assert :ok = UserDekRotation.rotate_user(user.id)

      reloaded_user =
        Repo.one!(from(u in Engram.Accounts.User, where: u.id == ^user.id), skip_tenant_check: true)

      # Round-trip: if rotation skipped the row, content still decrypts under old DEK
      # which is now gone → this would fail.
      {:ok, fetched} = Attachments.get_attachment(reloaded_user, vault, "regression/img.png")
      assert fetched.content == content
    end

    test "rotation works for note created via real upsert (dek_version=2 hardcoded)", %{
      user: user,
      vault: vault
    } do
      {:ok, _note} =
        Engram.Notes.upsert_note(user, vault, %{
          "path" => "regression/alpha.md",
          "content" => "regression alpha content",
          "mtime" => 1000.0
        })

      # Confirm the row was created at dek_version=2 (the production hardcode).
      {:ok, filter_key} = Crypto.dek_filter_key(user)
      path_hmac = Crypto.hmac_field(filter_key, "regression/alpha.md")

      raw =
        Repo.one!(
          from(n in Engram.Notes.Note,
            where: n.user_id == ^user.id and n.path_hmac == ^path_hmac
          ),
          skip_tenant_check: true
        )

      assert raw.dek_version == 2,
             "Expected upsert_note to stamp dek_version=2, got #{raw.dek_version}"

      # Rotate the DEK — should NOT skip this row despite dek_version already == 2.
      assert :ok = UserDekRotation.rotate_user(user.id)

      reloaded_user =
        Repo.one!(from(u in Engram.Accounts.User, where: u.id == ^user.id), skip_tenant_check: true)

      # Look up the note by path_hmac using the NEW filter key.
      {:ok, new_dek} = Crypto.get_dek(reloaded_user)
      new_filter_key = Crypto.dek_filter_key_from_bytes(new_dek)
      new_path_hmac = Crypto.hmac_field(new_filter_key, "regression/alpha.md")

      reloaded_note =
        Repo.one!(
          from(n in Engram.Notes.Note,
            where: n.user_id == ^user.id and n.path_hmac == ^new_path_hmac
          ),
          skip_tenant_check: true
        )

      # If rotation skipped the row, decrypt would fail under the new DEK.
      {:ok, decrypted} = Crypto.maybe_decrypt_note_fields(reloaded_note, reloaded_user)
      assert decrypted.content == "regression alpha content"
    end
  end

  describe "rotate_user/1 — fresh DEK on every call" do
    test "each call generates a distinct new DEK (no idempotence by design)", %{user: user} do
      assert :ok = UserDekRotation.rotate_user(user.id)

      reloaded =
        Repo.one!(from(u in Engram.Accounts.User, where: u.id == ^user.id), skip_tenant_check: true)

      first_wrapped = reloaded.encrypted_dek
      first_version = reloaded.dek_version

      # Second call: stale lock from prior run was cleared in final_flip → succeeds
      assert :ok = UserDekRotation.rotate_user(user.id)

      reloaded2 =
        Repo.one!(from(u in Engram.Accounts.User, where: u.id == ^user.id), skip_tenant_check: true)

      refute reloaded2.encrypted_dek == first_wrapped,
             "Expected a new wrapped DEK on second call"

      assert reloaded2.dek_version == first_version + 1,
             "Expected dek_version to increment on second call"
    end

    test "decrypt-as-discriminator handles notes already at new dek_version (idempotent sweep)",
         %{user: user} do
      # Create a v1-fixture note (dek_version=1, empty-AAD encryption).
      vault = Engram.Fixtures.insert_vault!(user, "SweepTest")

      note =
        Engram.Fixtures.insert_note!(user, vault, %{
          path: "sweep.md",
          content: "sweep content"
        })

      # First rotation: sweeps the note (v1 → v2), flips user DEK.
      assert :ok = UserDekRotation.rotate_user(user.id)

      reloaded_note =
        Repo.one!(from(n in Engram.Notes.Note, where: n.id == ^note.id), skip_tenant_check: true)

      assert reloaded_note.dek_version == 2

      # Second rotation: note is at dek_version=2, encrypted under DEK_v2.
      # The discriminator tries old_dek (DEK_v2) first — it succeeds → re-encrypts.
      # (On the second rotation the "old" DEK is DEK_v2 and "new" is DEK_v3.)
      assert :ok = UserDekRotation.rotate_user(user.id)

      reloaded_user =
        Repo.one!(from(u in Engram.Accounts.User, where: u.id == ^user.id), skip_tenant_check: true)

      reloaded_note2 =
        Repo.one!(from(n in Engram.Notes.Note, where: n.id == ^note.id), skip_tenant_check: true)

      assert reloaded_note2.dek_version == 3

      {:ok, decrypted} = Crypto.maybe_decrypt_note_fields(reloaded_note2, reloaded_user)
      assert decrypted.content == "sweep content"
    end
  end
end
