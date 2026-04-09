defmodule EngramWeb.AuthControllerTest do
  use EngramWeb.ConnCase, async: true

  # ---------------------------------------------------------------------------
  # POST /api-keys
  # ---------------------------------------------------------------------------

  describe "POST /api-keys" do
    setup %{conn: conn} do
      user = insert(:user)
      insert(:vault, user: user, is_default: true)
      {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "setup-key")
      authed = put_req_header(conn, "authorization", "Bearer #{api_key}")
      %{conn: authed, user: user}
    end

    test "creates an API key and returns raw key", %{conn: conn} do
      conn = post(conn, "/api/api-keys", %{name: "my-new-key"})

      assert %{"key" => key, "name" => name, "id" => id} = json_response(conn, 200)
      assert String.starts_with?(key, "engram_")
      assert name == "my-new-key"
      assert is_integer(id)
    end

    test "created key can authenticate requests", %{conn: conn} do
      %{"key" => new_key} =
        conn
        |> post("/api/api-keys", %{name: "usable-key"})
        |> json_response(200)

      # Use the newly created key to make an authenticated request (user-scoped endpoint)
      conn2 =
        build_conn()
        |> put_req_header("authorization", "Bearer #{new_key}")
        |> get("/api/me")

      assert json_response(conn2, 200)
    end

    test "returns 401 without auth", %{conn: conn} do
      conn =
        conn
        |> delete_req_header("authorization")
        |> post("/api/api-keys", %{name: "nope"})

      assert json_response(conn, 401)
    end
  end

  describe "DELETE /api-keys/:id" do
    setup %{conn: conn} do
      user = insert(:user)
      {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "setup-key")
      authed = put_req_header(conn, "authorization", "Bearer #{api_key}")
      %{conn: authed, user: user}
    end

    test "returns 400 for non-integer API key id", %{conn: conn} do
      conn = delete(conn, "/api/api-keys/abc")
      assert %{"error" => _} = json_response(conn, 400)
    end
  end
end
