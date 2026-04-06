defmodule Engram.IndexingTest do
  use Engram.DataCase, async: false

  import Mox

  alias Engram.Indexing
  alias Engram.Notes

  # Mox requires that expectations are verified after each test
  setup :verify_on_exit!

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

    user = insert(:user)

    {:ok, note} =
      Notes.upsert_note(user, %{
        "path" => "Health/Iron Panel.md",
        "content" => "---\ntags: [health]\n---\n# Iron Panel\n\nFerritin levels.",
        "mtime" => 1_000.0
      })

    %{bypass: bypass, user: user, note: note}
  end

  # ---------------------------------------------------------------------------
  # index_note/1
  # ---------------------------------------------------------------------------

  describe "index_note/1" do
    test "embeds chunks and upserts to Qdrant + Postgres", %{bypass: bypass, note: note} do
      # Mock embedder returns one 3-dim vector per chunk
      Engram.MockEmbedder
      |> expect(:embed_texts, fn texts ->
        vectors = Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)
        {:ok, vectors}
      end)

      # Qdrant: ensure_collection + delete + upsert
      Bypass.expect(bypass, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": true}))
      end)

      assert {:ok, chunk_count} = Indexing.index_note(note)
      assert chunk_count > 0

      # Postgres chunks rows should be created (skip_tenant_check: tests are trusted)
      import Ecto.Query
      chunks = Engram.Repo.all(from(c in Engram.Notes.Chunk), skip_tenant_check: true)
      assert length(chunks) == chunk_count
    end

    test "uses doc embed model when configured", %{bypass: bypass, note: note} do
      Application.put_env(:engram, :doc_embed_model, "voyage-4-large")
      on_exit(fn -> Application.delete_env(:engram, :doc_embed_model) end)

      Engram.MockEmbedder
      |> expect(:embed_texts, fn texts, [model: "voyage-4-large"] ->
        {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
      end)

      Bypass.expect(bypass, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": true}))
      end)

      assert {:ok, chunk_count} = Indexing.index_note(note)
      assert chunk_count > 0
    end

    test "skips embedding for empty content" do
      note = %Engram.Notes.Note{
        id: 999,
        path: "Test/Empty.md",
        content: "",
        user_id: 1,
        title: "Empty",
        folder: "Test",
        tags: [],
        version: 1,
        content_hash: ""
      }

      assert {:ok, 0} = Indexing.index_note(note)
    end
  end

  # ---------------------------------------------------------------------------
  # delete_note_index/1
  # ---------------------------------------------------------------------------

  describe "delete_note_index/1" do
    test "deletes chunks from Postgres and Qdrant", %{bypass: bypass, note: note} do
      # First index it
      Engram.MockEmbedder
      |> expect(:embed_texts, fn texts ->
        {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
      end)

      Bypass.expect(bypass, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": true}))
      end)

      {:ok, _} = Indexing.index_note(note)

      # Now delete — Qdrant should get a delete request
      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/delete", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": {"status": "ok"}}))
      end)

      assert :ok = Indexing.delete_note_index(note)

      # Postgres chunks should be gone
      import Ecto.Query

      chunks =
        Engram.Repo.all(from(c in Engram.Notes.Chunk, where: c.note_id == ^note.id),
          skip_tenant_check: true
        )

      assert chunks == []
    end
  end
end
