defmodule Engram.Vector.QdrantTest do
  use ExUnit.Case, async: true

  alias Engram.Vector.Qdrant

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)
    %{bypass: bypass}
  end

  describe "ensure_collection/2" do
    test "creates collection with correct dims", %{bypass: bypass} do
      Bypass.expect_once(bypass, "PUT", "/collections/test_col", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["vectors"]["size"] == 1024

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": true}))
      end)

      assert :ok = Qdrant.ensure_collection("test_col", 1024)
    end
  end

  describe "upsert_points/2" do
    test "puts points to collection", %{bypass: bypass} do
      points = [
        %{id: "uuid-1", vector: [0.1, 0.2], payload: %{user_id: "1", path: "a.md"}}
      ]

      Bypass.expect_once(bypass, "PUT", "/collections/test_col/points", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert length(decoded["points"]) == 1

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": {"status": "ok"}}))
      end)

      assert :ok = Qdrant.upsert_points("test_col", points)
    end
  end

  describe "delete_by_note/3" do
    test "posts filter delete for user+path", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/collections/test_col/points/delete", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        conditions = decoded["filter"]["must"]
        keys = Enum.map(conditions, & &1["key"])
        assert "user_id" in keys
        assert "source_path" in keys

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": {"status": "ok"}}))
      end)

      assert :ok = Qdrant.delete_by_note("test_col", "user-1", "Test/Note.md")
    end
  end

  describe "search/3" do
    test "returns search results", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/collections/test_col/points/query", fn conn ->
        resp = %{
          "result" => [
            %{
              "id" => "uuid-1",
              "score" => 0.95,
              "payload" => %{
                "text" => "hello",
                "title" => "Note",
                "heading_path" => "Note > Section",
                "source_path" => "Test/Note.md",
                "tags" => [],
                "user_id" => "1"
              }
            }
          ]
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(resp))
      end)

      vector = List.duplicate(0.1, 1024)
      assert {:ok, results} = Qdrant.search("test_col", vector, user_id: "1", limit: 5)
      assert length(results) == 1
      assert hd(results).score == 0.95
    end

    test "returns empty list when no results", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/collections/test_col/points/query", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": []}))
      end)

      assert {:ok, []} = Qdrant.search("test_col", [0.1], user_id: "1", limit: 5)
    end

    test "returns error on failure", %{bypass: bypass} do
      Bypass.down(bypass)
      assert {:error, _} = Qdrant.search("test_col", [0.1], user_id: "1", limit: 5)
    end
  end
end
