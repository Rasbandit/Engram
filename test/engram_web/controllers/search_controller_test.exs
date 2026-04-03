defmodule EngramWeb.SearchControllerTest do
  use EngramWeb.ConnCase, async: false

  import Mox

  setup :verify_on_exit!

  setup %{conn: conn} do
    user = insert(:user)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    authed = put_req_header(conn, "authorization", "Bearer #{api_key}")

    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

    %{conn: authed, user: user, bypass: bypass}
  end

  describe "POST /search" do
    test "returns results for a valid query", %{conn: conn, bypass: bypass, user: user} do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn _ -> {:ok, [List.duplicate(0.1, 3)]} end)

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

      Bypass.expect_once(bypass, "POST", "/collections/obsidian_notes/points/query", fn c ->
        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(qdrant_result))
      end)

      conn = post(conn, "/search", %{query: "iron panel"})
      assert %{"results" => results} = json_response(conn, 200)
      assert length(results) == 1
      assert hd(results)["score"] == 0.95
      assert hd(results)["source_path"] == "Health/Iron Panel.md"
    end

    test "passes limit param", %{conn: conn, bypass: bypass} do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      Bypass.expect_once(bypass, "POST", "/collections/obsidian_notes/points/query", fn c ->
        {:ok, body, c} = Plug.Conn.read_body(c)
        decoded = Jason.decode!(body)
        assert decoded["limit"] == 10

        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": []}))
      end)

      conn = post(conn, "/search", %{query: "test", limit: 10})
      assert %{"results" => []} = json_response(conn, 200)
    end

    test "returns 422 when query is missing", %{conn: conn} do
      conn = post(conn, "/search", %{})
      assert json_response(conn, 422)
    end

    test "returns 401 without auth", %{conn: conn} do
      conn =
        conn
        |> delete_req_header("authorization")
        |> post("/search", %{query: "test"})

      assert json_response(conn, 401)
    end

    test "returns empty results list when nothing found", %{conn: conn, bypass: bypass} do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      Bypass.expect_once(bypass, "POST", "/collections/obsidian_notes/points/query", fn c ->
        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": []}))
      end)

      conn = post(conn, "/search", %{query: "nothing here"})
      assert %{"results" => []} = json_response(conn, 200)
    end
  end
end
