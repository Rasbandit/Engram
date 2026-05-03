defmodule Engram.Workers.BackfillPhaseBHmacTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query

  alias Engram.Attachments.Attachment
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Vaults.Vault
  alias Engram.Workers.BackfillPhaseBHmac

  setup do
    {:ok, user} =
      insert(:user)
      |> Engram.Crypto.ensure_user_dek()

    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  describe "perform/1 — notes" do
    test "backfills HMAC + ciphertext for legacy notes missing Phase B columns",
         %{user: user, vault: vault} do
      # Insert directly via Repo to bypass upsert_note (leaves Phase B columns nil)
      {:ok, _} =
        Repo.with_tenant(user.id, fn ->
          %Note{}
          |> Note.changeset(%{
            path: "legacy/note.md",
            folder: "legacy",
            content: "x",
            tags: ["t1"],
            user_id: user.id,
            vault_id: vault.id
          })
          |> Repo.insert()
        end)

      :ok =
        perform_job(BackfillPhaseBHmac, %{
          "user_id" => user.id,
          "vault_id" => vault.id,
          "last_id" => 0
        })

      {:ok, notes} =
        Repo.with_tenant(user.id, fn ->
          Repo.all(from(n in Note, where: n.path == "legacy/note.md"))
        end)

      note = hd(notes)
      assert is_binary(note.path_hmac)
      assert is_binary(note.path_ciphertext)
      assert is_binary(note.path_nonce)
      assert is_binary(note.folder_hmac)
      assert is_binary(note.folder_ciphertext)
      assert is_binary(note.folder_nonce)
      assert note.tags_hmac != []
      assert length(note.tags_hmac) == 1
    end

    test "skips notes that already have path_hmac set", %{user: user, vault: vault} do
      # Insert two notes: one legacy (nil), one already backfilled (non-nil)
      {:ok, _} =
        Repo.with_tenant(user.id, fn ->
          %Note{}
          |> Note.changeset(%{
            path: "fresh/already-done.md",
            folder: "fresh",
            content: "x",
            tags: [],
            user_id: user.id,
            vault_id: vault.id,
            path_hmac: <<1::256>>,
            path_ciphertext: <<2::128>>,
            path_nonce: <<3::96>>
          })
          |> Repo.insert()
        end)

      :ok =
        perform_job(BackfillPhaseBHmac, %{
          "user_id" => user.id,
          "vault_id" => vault.id,
          "last_id" => 0
        })

      {:ok, notes} =
        Repo.with_tenant(user.id, fn ->
          Repo.all(from(n in Note, where: n.path == "fresh/already-done.md"))
        end)

      note = hd(notes)
      # Should not have been overwritten
      assert note.path_hmac == <<1::256>>
    end

    test "is idempotent — second run does not change values", %{user: user, vault: vault} do
      {:ok, _} =
        Repo.with_tenant(user.id, fn ->
          %Note{}
          |> Note.changeset(%{
            path: "idem/note.md",
            folder: "idem",
            content: "y",
            tags: ["a", "b"],
            user_id: user.id,
            vault_id: vault.id
          })
          |> Repo.insert()
        end)

      :ok =
        perform_job(BackfillPhaseBHmac, %{
          "user_id" => user.id,
          "vault_id" => vault.id,
          "last_id" => 0
        })

      {:ok, [after_first]} =
        Repo.with_tenant(user.id, fn ->
          Repo.all(from(n in Note, where: n.path == "idem/note.md"))
        end)

      :ok =
        perform_job(BackfillPhaseBHmac, %{
          "user_id" => user.id,
          "vault_id" => vault.id,
          "last_id" => 0
        })

      {:ok, [after_second]} =
        Repo.with_tenant(user.id, fn ->
          Repo.all(from(n in Note, where: n.path == "idem/note.md"))
        end)

      assert after_first.path_hmac == after_second.path_hmac
      assert after_first.path_ciphertext == after_second.path_ciphertext
      assert after_first.tags_hmac == after_second.tags_hmac
    end

    test "re-enqueues with new cursor when batch is full", %{user: user, vault: vault} do
      # Insert 100 legacy notes to fill a batch
      Repo.with_tenant(user.id, fn ->
        for i <- 1..100 do
          %Note{}
          |> Note.changeset(%{
            path: "batch/note-#{i}.md",
            folder: "batch",
            content: "c",
            tags: [],
            user_id: user.id,
            vault_id: vault.id
          })
          |> Repo.insert!()
        end
      end)

      :ok =
        perform_job(BackfillPhaseBHmac, %{
          "user_id" => user.id,
          "vault_id" => vault.id,
          "last_id" => 0
        })

      assert_enqueued(worker: BackfillPhaseBHmac)
    end

    test "returns :ok and does not re-enqueue when batch is empty", %{user: user, vault: vault} do
      :ok =
        perform_job(BackfillPhaseBHmac, %{
          "user_id" => user.id,
          "vault_id" => vault.id,
          "last_id" => 0
        })

      refute_enqueued(worker: BackfillPhaseBHmac)
    end
  end

  describe "perform/1 — attachments" do
    test "backfills path_* for legacy attachments", %{user: user, vault: vault} do
      {:ok, _} =
        Repo.with_tenant(user.id, fn ->
          %Attachment{}
          |> Ecto.Changeset.change(%{
            path: "files/image.png",
            content_hash: "abc123",
            mime_type: "image/png",
            size_bytes: 4,
            content_nonce: <<0::96>>,
            encryption_version: 1,
            user_id: user.id,
            vault_id: vault.id
          })
          |> Repo.insert()
        end)

      :ok =
        perform_job(BackfillPhaseBHmac, %{
          "user_id" => user.id,
          "vault_id" => vault.id,
          "last_id" => 0
        })

      {:ok, attachments} =
        Repo.with_tenant(user.id, fn ->
          Repo.all(from(a in Attachment, where: a.path == "files/image.png"))
        end)

      att = hd(attachments)
      assert is_binary(att.path_hmac)
      assert is_binary(att.path_ciphertext)
      assert is_binary(att.path_nonce)
    end
  end

  describe "perform/1 — vaults" do
    test "backfills name_* for vault missing Phase B columns", %{user: user, vault: vault} do
      # Ensure name_hmac is nil (factory doesn't set it)
      assert is_nil(vault.name_hmac)

      :ok =
        perform_job(BackfillPhaseBHmac, %{
          "user_id" => user.id,
          "vault_id" => vault.id,
          "last_id" => 0
        })

      updated = Repo.get!(Vault, vault.id, skip_tenant_check: true)
      assert is_binary(updated.name_hmac)
      assert is_binary(updated.name_ciphertext)
      assert is_binary(updated.name_nonce)
    end
  end
end
