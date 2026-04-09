defmodule EngramWeb.SearchControllerTest do
  use EngramWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Mox

  setup :verify_on_exit!

  setup %{conn: conn} do
    user = insert(:user)
    _vault = insert(:vault, user: user, is_default: true)
    subscription_fixture(user)
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

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn c ->
        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(qdrant_result))
      end)

      conn = post(conn, "/api/search", %{query: "iron panel"})
      assert %{"results" => results} = json_response(conn, 200)
      assert length(results) == 1
      assert hd(results)["score"] == 0.95
      assert hd(results)["source_path"] == "Health/Iron Panel.md"
    end

    test "passes limit param", %{conn: conn, bypass: bypass} do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn c ->
        {:ok, body, c} = Plug.Conn.read_body(c)
        decoded = Jason.decode!(body)
        assert decoded["limit"] == 10

        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": []}))
      end)

      conn = post(conn, "/api/search", %{query: "test", limit: 10})
      assert %{"results" => []} = json_response(conn, 200)
    end

    test "returns 422 when query is missing", %{conn: conn} do
      conn = post(conn, "/api/search", %{})
      assert json_response(conn, 422)
    end

    test "clamps limit to valid range", %{conn: conn, bypass: bypass} do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn c ->
        {:ok, body, c} = Plug.Conn.read_body(c)
        decoded = Jason.decode!(body)
        assert decoded["limit"] <= 50

        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": []}))
      end)

      conn = post(conn, "/api/search", %{query: "test", limit: 999})
      assert json_response(conn, 200)
    end

    test "returns 401 without auth", %{conn: conn} do
      conn =
        conn
        |> delete_req_header("authorization")
        |> post("/api/search", %{query: "test"})

      assert json_response(conn, 401)
    end

    test "does not leak internal details on search error", %{conn: conn, bypass: bypass} do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      Bypass.expect(bypass, "POST", "/collections/engram_notes/points/query", fn c ->
        Plug.Conn.send_resp(c, 500, ~s({"status":{"error":"Qdrant internal"}}))
      end)

      {conn, _log} =
        with_log(fn ->
          post(conn, "/api/search", %{query: "test"})
        end)

      body = json_response(conn, 500)
      # Must NOT contain internal Elixir terms or adapter details
      refute String.contains?(body["error"], "Qdrant")
      refute String.contains?(body["error"], "%{")
      refute String.contains?(body["error"], "Elixir")
    end

    test "returns empty results list when nothing found", %{conn: conn, bypass: bypass} do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn c ->
        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": []}))
      end)

      conn = post(conn, "/api/search", %{query: "nothing here"})
      assert %{"results" => []} = json_response(conn, 200)
    end
  end
end
