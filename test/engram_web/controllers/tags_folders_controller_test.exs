defmodule EngramWeb.TagsFoldersControllerTest do
  use EngramWeb.ConnCase, async: true

  setup %{conn: conn} do
    user = insert(:user)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    authed = put_req_header(conn, "authorization", "Bearer #{api_key}")
    %{conn: authed, user: user}
  end

  describe "GET /tags" do
    test "returns unique tags for user", %{conn: conn} do
      post(conn, "/notes", %{
        path: "A.md",
        content: "---\ntags: [health, fitness]\n---",
        mtime: 1_000.0
      })

      post(conn, "/notes", %{
        path: "B.md",
        content: "---\ntags: [health, nutrition]\n---",
        mtime: 1_000.0
      })

      conn = get(conn, "/tags")
      assert %{"tags" => tags} = json_response(conn, 200)
      assert "health" in tags
      assert "fitness" in tags
      assert "nutrition" in tags
      assert Enum.count(tags, &(&1 == "health")) == 1
    end

    test "returns 401 without auth" do
      conn =
        build_conn()
        |> get("/tags")

      assert json_response(conn, 401)
    end
  end

  describe "GET /folders" do
    test "returns unique folders for user", %{conn: conn} do
      post(conn, "/notes", %{path: "Folder A/Note.md", content: "x", mtime: 1_000.0})
      post(conn, "/notes", %{path: "Folder B/Note.md", content: "x", mtime: 1_000.0})
      post(conn, "/notes", %{path: "Folder A/Other.md", content: "x", mtime: 1_000.0})

      conn = get(conn, "/folders")
      assert %{"folders" => folders} = json_response(conn, 200)
      assert "Folder A" in folders
      assert "Folder B" in folders
      assert Enum.count(folders, &(&1 == "Folder A")) == 1
    end

    test "returns 401 without auth" do
      conn =
        build_conn()
        |> get("/folders")

      assert json_response(conn, 401)
    end
  end
end
