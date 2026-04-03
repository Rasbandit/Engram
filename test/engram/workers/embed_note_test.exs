defmodule Engram.Workers.EmbedNoteTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Mox

  alias Engram.Notes
  alias Engram.Workers.EmbedNote

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

  describe "perform/1" do
    test "indexes note and returns :ok", %{bypass: bypass, note: note} do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn texts ->
        {:ok, Enum.map(texts, fn _ -> List.duplicate(0.1, 3) end)}
      end)

      # Qdrant: ensure_collection + delete_by_note + upsert_points
      Bypass.expect(bypass, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": true}))
      end)

      assert :ok = perform_job(EmbedNote, %{note_id: note.id})
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
