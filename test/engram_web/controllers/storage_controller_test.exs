defmodule EngramWeb.StorageControllerTest do
  use EngramWeb.ConnCase, async: true

  setup %{conn: conn} do
    user = insert(:user)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    authed = put_req_header(conn, "authorization", "Bearer #{api_key}")
    %{conn: authed, user: user}
  end

  describe "GET /user/storage" do
    test "returns zero usage for new user", %{conn: conn} do
      conn = get(conn, "/user/storage")
      body = json_response(conn, 200)

      assert body["used_bytes"] == 0
      assert body["file_count"] == 0
      assert is_integer(body["max_bytes"])
      assert is_integer(body["max_attachment_bytes"])
    end

    test "reflects uploaded attachment size", %{conn: conn} do
      content = String.duplicate("x", 1000)

      post(conn, "/attachments", %{
        path: "photos/big.png",
        content_base64: Base.encode64(content),
        mtime: 1_000.0
      })

      conn2 = get(conn, "/user/storage")
      body = json_response(conn2, 200)

      assert body["used_bytes"] == 1000
      assert body["file_count"] == 1
    end

    test "excludes deleted attachments from usage", %{conn: conn} do
      post(conn, "/attachments", %{
        path: "photos/del.png",
        content_base64: Base.encode64("data"),
        mtime: 1_000.0
      })

      delete(conn, "/attachments/photos/del.png")

      conn2 = get(conn, "/user/storage")
      body = json_response(conn2, 200)

      assert body["used_bytes"] == 0
      assert body["file_count"] == 0
    end

    test "returns 401 without auth", %{conn: conn} do
      conn =
        conn
        |> delete_req_header("authorization")
        |> get("/user/storage")

      assert json_response(conn, 401)
    end
  end
end
