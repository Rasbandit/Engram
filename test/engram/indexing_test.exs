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
    vault = insert(:vault, user: user)

    {:ok, note} =
      Notes.upsert_note(user, vault, %{
        "path" => "Health/Iron Panel.md",
        "content" => "---\ntags: [health]\n---\n# Iron Panel\n\nFerritin levels.",
        "mtime" => 1_000.0
      })

    %{bypass: bypass, user: user, vault: vault, note: note}
  end

  # ---------------------------------------------------------------------------
  # index_note/2
  # ---------------------------------------------------------------------------

  describe "index_note/2" do
    test "embeds chunks and upserts to Qdrant + Postgres", %{bypass: bypass, note: note, vault: vault} do
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

      assert {:ok, chunk_count} = Indexing.index_note(note, vault)
      assert chunk_count > 0

      # Postgres chunks rows should be created (skip_tenant_check: tests are trusted)
      import Ecto.Query
      chunks = Engram.Repo.all(from(c in Engram.Notes.Chunk), skip_tenant_check: true)
      assert length(chunks) == chunk_count
    end

    test "uses doc embed model when configured", %{bypass: bypass, note: note, vault: vault} do
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

      assert {:ok, chunk_count} = Indexing.index_note(note, vault)
      assert chunk_count > 0
    end

    test "skips embedding for empty content", %{vault: vault} do
      note = %Engram.Notes.Note{
        id: 999,
        path: "Test/Empty.md",
        content: "",
        user_id: 1,
        vault_id: 1,
        title: "Empty",
        folder: "Test",
        tags: [],
        version: 1,
        content_hash: ""
      }

      assert {:ok, 0} = Indexing.index_note(note, vault)
    end
  end

  # ---------------------------------------------------------------------------
  # index_note/2 with encrypted vault
  # ---------------------------------------------------------------------------

  describe "index_note/2 with encrypted vault" do
    test "encrypts text/title/heading_path in Qdrant payload", %{bypass: bypass, user: user} do
      Engram.Crypto.DekCache.invalidate_all()
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)
      vault = insert(:vault, user: user, encrypted: true)

      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "secret/note.md",
          "content" => "# Secret\n\nClassified body.",
          "mtime" => 1_000.0
        })

      # Re-decrypt since upsert_note encrypted the note content (Phase 3 behaviour).
      {:ok, note} = Engram.Crypto.maybe_decrypt_note_fields(note, user)

      Engram.MockEmbedder
      |> expect(:embed_texts, fn texts ->
        {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
      end)

      test_pid = self()

      Bypass.expect(bypass, fn conn ->
        if String.contains?(conn.request_path, "/points") and conn.method == "PUT" do
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:upsert_body, Jason.decode!(body)})
          Plug.Conn.send_resp(conn, 200, ~s({"result": true}))
        else
          Plug.Conn.send_resp(conn, 200, ~s({"result": true}))
        end
      end)

      assert {:ok, _count} = Indexing.index_note(note, vault)

      assert_received {:upsert_body, body}
      points = body["points"]
      assert length(points) > 0

      Enum.each(points, fn p ->
        payload = p["payload"]
        assert Map.has_key?(payload, "text_nonce")
        assert Map.has_key?(payload, "title_nonce")
        assert Map.has_key?(payload, "heading_path_nonce")
        # text should be base64-encoded ciphertext, not the plaintext
        refute payload["text"] == "Classified body."
        refute payload["text"] =~ "Classified"
        assert is_binary(payload["text_nonce"])
        # base64 round-trip should succeed
        assert {:ok, _} = Base.decode64(payload["text"])
        assert {:ok, _} = Base.decode64(payload["text_nonce"])
      end)
    end

    test "unencrypted vault → plaintext payload unchanged", %{bypass: bypass, user: user} do
      vault = insert(:vault, user: user, encrypted: false)

      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "plain/note.md",
          "content" => "Plain body",
          "mtime" => 1_000.0
        })

      Engram.MockEmbedder
      |> expect(:embed_texts, fn texts ->
        {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
      end)

      test_pid = self()

      Bypass.expect(bypass, fn conn ->
        if String.contains?(conn.request_path, "/points") and conn.method == "PUT" do
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:upsert_body, Jason.decode!(body)})
          Plug.Conn.send_resp(conn, 200, ~s({"result": true}))
        else
          Plug.Conn.send_resp(conn, 200, ~s({"result": true}))
        end
      end)

      assert {:ok, _} = Indexing.index_note(note, vault)
      assert_received {:upsert_body, body}

      Enum.each(body["points"], fn p ->
        refute Map.has_key?(p["payload"], "text_nonce")
        refute Map.has_key?(p["payload"], "title_nonce")
        refute Map.has_key?(p["payload"], "heading_path_nonce")
        assert is_binary(p["payload"]["text"])
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # delete_note_index/1
  # ---------------------------------------------------------------------------

  describe "delete_note_index/1" do
    test "deletes chunks from Postgres and Qdrant", %{bypass: bypass, note: note, vault: vault} do
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

      {:ok, _} = Indexing.index_note(note, vault)

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
