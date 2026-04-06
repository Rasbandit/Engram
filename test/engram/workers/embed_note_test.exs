defmodule Engram.Workers.EmbedNoteTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Mox

  alias Engram.Notes
  alias Engram.Notes.Note
  alias Engram.Workers.EmbedNote
  alias Engram.Repo

  setup :verify_on_exit!

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

    user = insert(:user)
    # Use factory directly — avoids triggering EmbedNote inline during setup
    note = insert(:note, user: user, path: "Test/Hello.md", content: "# Hello\n\nWorld.")
    %{bypass: bypass, user: user, note: note}
  end

  defp stub_qdrant(bypass) do
    Bypass.expect(bypass, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true}))
    end)
  end

  describe "perform/1" do
    test "indexes note and returns :ok", %{bypass: bypass, note: note} do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn texts ->
        {:ok, Enum.map(texts, fn _ -> List.duplicate(0.1, 3) end)}
      end)

      stub_qdrant(bypass)

      assert :ok = perform_job(EmbedNote, %{note_id: note.id})
    end

    test "stamps embed_hash on success", %{bypass: bypass, note: note} do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn texts ->
        {:ok, Enum.map(texts, fn _ -> List.duplicate(0.1, 3) end)}
      end)

      stub_qdrant(bypass)

      assert :ok = perform_job(EmbedNote, %{note_id: note.id})

      updated = Repo.get!(Note, note.id, skip_tenant_check: true)
      assert updated.embed_hash == updated.content_hash
    end

    test "skips embedding when embed_hash matches content_hash", %{note: note} do
      # Pre-set embed_hash to match content_hash
      import Ecto.Query

      from(n in Note, where: n.id == ^note.id)
      |> Repo.update_all([set: [embed_hash: note.content_hash]], skip_tenant_check: true)

      # No mock expectations — if it tried to embed, Mox would fail
      assert :ok = perform_job(EmbedNote, %{note_id: note.id})
    end

    test "optimistic lock: does not stamp embed_hash if content changed mid-embed", %{
      bypass: bypass,
      note: note
    } do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn texts ->
        # Simulate concurrent edit: change content_hash while embedding
        import Ecto.Query

        from(n in Note, where: n.id == ^note.id)
        |> Repo.update_all([set: [content_hash: "changed_during_embed"]],
          skip_tenant_check: true
        )

        {:ok, Enum.map(texts, fn _ -> List.duplicate(0.1, 3) end)}
      end)

      stub_qdrant(bypass)

      assert :ok = perform_job(EmbedNote, %{note_id: note.id})

      updated = Repo.get!(Note, note.id, skip_tenant_check: true)
      # embed_hash should NOT have been set (content_hash changed)
      assert is_nil(updated.embed_hash)
    end

    test "discards job when note doesn't exist" do
      assert {:discard, _} = perform_job(EmbedNote, %{note_id: 999_999})
    end

    test "discards job when note is soft-deleted", %{user: user} do
      note = insert(:note, user: user, deleted_at: DateTime.utc_now())
      assert {:discard, _} = perform_job(EmbedNote, %{note_id: note.id})
    end
  end

  describe "job scheduling" do
    test "Notes.upsert_note enqueues EmbedNote job", %{user: user} do
      {:ok, note} =
        Notes.upsert_note(user, %{
          "path" => "Test/Scheduled.md",
          "content" => "# Scheduled",
          "mtime" => 1_000.0
        })

      # Oban is in :manual mode globally — jobs stay in 'scheduled' state for assertion
      assert_enqueued(worker: EmbedNote, args: %{"note_id" => note.id})
    end

    test "upsert with unchanged content does not enqueue embed job", %{user: user} do
      {:ok, note} =
        Notes.upsert_note(user, %{
          "path" => "Test/NoChange.md",
          "content" => "# Same content",
          "mtime" => 1_000.0
        })

      # First upsert triggers embed
      assert_enqueued(worker: EmbedNote, args: %{"note_id" => note.id})

      # Re-upsert with same content — should not enqueue another
      {:ok, _} =
        Notes.upsert_note(user, %{
          "path" => "Test/NoChange.md",
          "content" => "# Same content",
          "mtime" => 2_000.0
        })

      # Still only one job
      jobs = all_enqueued(worker: EmbedNote)
      assert length(jobs) == 1
    end

    test "delete_note does not enqueue an additional embed job", %{user: user} do
      {:ok, note} =
        Notes.upsert_note(user, %{
          "path" => "Test/Gone.md",
          "content" => "# Gone",
          "mtime" => 1_000.0
        })

      Notes.delete_note(user, note.path)

      # Only the upsert job, nothing from delete
      jobs = all_enqueued(worker: EmbedNote)
      assert length(jobs) == 1
    end
  end
end
