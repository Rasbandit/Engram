defmodule Engram.SearchTest do
  use Engram.DataCase, async: false

  import Mox

  alias Engram.Search

  setup :verify_on_exit!

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

    user = insert(:user)
    %{bypass: bypass, user: user}
  end

  describe "search/3" do
    test "returns results from Qdrant", %{bypass: bypass, user: user} do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn ["iron panel"] ->
        {:ok, [List.duplicate(0.1, 3)]}
      end)

      qdrant_result = %{
        "result" => [
          %{
            "id" => "uuid-1",
            "score" => 0.95,
            "payload" => %{
              "text" => "Ferritin levels.",
              "title" => "Iron Panel",
              "heading_path" => "Iron Panel",
              "source_path" => "Health/Iron Panel.md",
              "tags" => ["health"],
              "user_id" => to_string(user.id)
            }
          }
        ]
      }

      Bypass.expect_once(bypass, "POST", "/collections/obsidian_notes/points/query", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(qdrant_result))
      end)

      assert {:ok, results} = Search.search(user, "iron panel")
      assert length(results) == 1
      assert hd(results).score == 0.95
      assert hd(results).source_path == "Health/Iron Panel.md"
    end

    test "passes folder filter to Qdrant", %{bypass: bypass, user: user} do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      Bypass.expect_once(bypass, "POST", "/collections/obsidian_notes/points/query", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        conditions = decoded["filter"]["must"]
        keys = Enum.map(conditions, & &1["key"])
        assert "folder" in keys

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": []}))
      end)

      assert {:ok, []} = Search.search(user, "query", folder: "Health")
    end

    test "passes tags filter to Qdrant", %{bypass: bypass, user: user} do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      Bypass.expect_once(bypass, "POST", "/collections/obsidian_notes/points/query", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        conditions = decoded["filter"]["must"]
        keys = Enum.map(conditions, & &1["key"])
        assert "tags" in keys

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": []}))
      end)

      assert {:ok, []} = Search.search(user, "query", tags: ["health"])
    end

    test "returns error when embedder fails", %{user: user} do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn _ -> {:error, :unavailable} end)

      assert {:error, _} = Search.search(user, "iron panel")
    end

    test "fetches 4x candidates when reranker is configured", %{bypass: bypass, user: user} do
      # Configure Jina reranker via behaviour
      jina_bypass = Bypass.open()
      Application.put_env(:engram, :reranker, Engram.Rerankers.Jina)
      Application.put_env(:engram, :jina_url, "http://localhost:#{jina_bypass.port}")

      on_exit(fn ->
        Application.put_env(:engram, :reranker, Engram.Rerankers.None)
        Application.delete_env(:engram, :jina_url)
      end)

      Engram.MockEmbedder
      |> expect(:embed_texts, fn _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      Bypass.expect_once(bypass, "POST", "/collections/obsidian_notes/points/query", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        # With limit=2, should request 4x = 8, but min 20
        assert decoded["limit"] == 20

        results =
          for i <- 0..3 do
            %{
              "id" => "uuid-#{i}",
              "score" => 0.9 - i * 0.1,
              "payload" => %{
                "text" => "Result #{i}",
                "title" => "Note #{i}",
                "heading_path" => "Section",
                "source_path" => "test/note#{i}.md",
                "tags" => [],
                "user_id" => to_string(user.id)
              }
            }
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"result" => results}))
      end)

      Bypass.expect_once(jina_bypass, "POST", "/rerank", fn conn ->
        resp = %{
          "results" => [
            %{"index" => 3, "relevance_score" => 0.99},
            %{"index" => 0, "relevance_score" => 0.80},
            %{"index" => 1, "relevance_score" => 0.50},
            %{"index" => 2, "relevance_score" => 0.30}
          ]
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(resp))
      end)

      assert {:ok, results} = Search.search(user, "test query", limit: 2)
      assert length(results) == 2
      # Result 3 should be first (highest reranker score)
      assert hd(results).source_path == "test/note3.md"
    end

    test "uses query embed model when configured", %{bypass: bypass, user: user} do
      Application.put_env(:engram, :query_embed_model, "voyage-4-lite")
      on_exit(fn -> Application.delete_env(:engram, :query_embed_model) end)

      Engram.MockEmbedder
      |> expect(:embed_texts, fn ["test query"], [model: "voyage-4-lite"] ->
        {:ok, [List.duplicate(0.1, 3)]}
      end)

      Bypass.expect_once(bypass, "POST", "/collections/obsidian_notes/points/query", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": []}))
      end)

      assert {:ok, []} = Search.search(user, "test query")
    end

    test "uses default embed when query model not configured", %{bypass: bypass, user: user} do
      Application.delete_env(:engram, :query_embed_model)

      Engram.MockEmbedder
      |> expect(:embed_texts, fn ["test query"] ->
        {:ok, [List.duplicate(0.1, 3)]}
      end)

      Bypass.expect_once(bypass, "POST", "/collections/obsidian_notes/points/query", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": []}))
      end)

      assert {:ok, []} = Search.search(user, "test query")
    end

    test "returns empty list when Qdrant returns no results", %{bypass: bypass, user: user} do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      Bypass.expect_once(bypass, "POST", "/collections/obsidian_notes/points/query", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": []}))
      end)

      assert {:ok, []} = Search.search(user, "nothing")
    end
  end
end
