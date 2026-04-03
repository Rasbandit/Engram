defmodule EngramWeb.AuthControllerTest do
  use EngramWeb.ConnCase, async: false

  # ---------------------------------------------------------------------------
  # POST /users/register
  # ---------------------------------------------------------------------------

  describe "POST /users/register" do
    test "registers a new user and returns JWT", %{conn: conn} do
      conn =
        post(conn, "/users/register", %{
          email: "newuser@test.com",
          password: "password123"
        })

      assert %{"user" => user, "token" => token} = json_response(conn, 200)
      assert user["email"] == "newuser@test.com"
      assert is_integer(user["id"])
      assert is_binary(token) and byte_size(token) > 0
    end

    test "rejects duplicate email", %{conn: conn} do
      post(conn, "/users/register", %{email: "dup@test.com", password: "password123"})

      conn2 = post(conn, "/users/register", %{email: "dup@test.com", password: "password123"})
      assert %{"errors" => _} = json_response(conn2, 422)
    end

    test "rejects missing email", %{conn: conn} do
      conn = post(conn, "/users/register", %{password: "password123"})
      assert %{"errors" => errors} = json_response(conn, 422)
      assert errors["email"]
    end

    test "rejects missing password", %{conn: conn} do
      conn = post(conn, "/users/register", %{email: "nopass@test.com"})
      assert %{"errors" => errors} = json_response(conn, 422)
      assert errors["password"]
    end
  end

  # ---------------------------------------------------------------------------
  # POST /users/login
  # ---------------------------------------------------------------------------

  describe "POST /users/login" do
    setup %{conn: conn} do
      resp =
        conn
        |> post("/users/register", %{email: "login@test.com", password: "password123"})
        |> json_response(200)

      %{user_id: resp["user"]["id"]}
    end

    test "authenticates with valid credentials", %{conn: conn} do
      conn =
        post(conn, "/users/login", %{email: "login@test.com", password: "password123"})

      assert %{"user" => user, "token" => token} = json_response(conn, 200)
      assert user["email"] == "login@test.com"
      assert is_binary(token)
    end

    test "rejects wrong password", %{conn: conn} do
      conn = post(conn, "/users/login", %{email: "login@test.com", password: "wrong"})
      assert %{"error" => _} = json_response(conn, 401)
    end

    test "rejects nonexistent email", %{conn: conn} do
      conn = post(conn, "/users/login", %{email: "nobody@test.com", password: "password123"})
      assert %{"error" => _} = json_response(conn, 401)
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api-keys
  # ---------------------------------------------------------------------------

  describe "POST /api-keys" do
    setup %{conn: conn} do
      user = insert(:user)
      {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "setup-key")
      authed = put_req_header(conn, "authorization", "Bearer #{api_key}")
      %{conn: authed, user: user}
    end

    test "creates an API key and returns raw key", %{conn: conn} do
      conn = post(conn, "/api-keys", %{name: "my-new-key"})

      assert %{"key" => key, "name" => name, "id" => id} = json_response(conn, 200)
      assert String.starts_with?(key, "engram_")
      assert name == "my-new-key"
      assert is_integer(id)
    end

    test "created key can authenticate requests", %{conn: conn} do
      %{"key" => new_key} =
        conn
        |> post("/api-keys", %{name: "usable-key"})
        |> json_response(200)

      # Use the newly created key to make an authenticated request
      conn2 =
        build_conn()
        |> put_req_header("authorization", "Bearer #{new_key}")
        |> get("/tags")

      assert json_response(conn2, 200)
    end

    test "returns 401 without auth", %{conn: conn} do
      conn =
        conn
        |> delete_req_header("authorization")
        |> post("/api-keys", %{name: "nope"})

      assert json_response(conn, 401)
    end
  end

  # ---------------------------------------------------------------------------
  # JWT token validation
  # ---------------------------------------------------------------------------

  describe "JWT authentication" do
    test "JWT from registration can authenticate API requests", %{conn: conn} do
      %{"token" => jwt} =
        conn
        |> post("/users/register", %{email: "jwt@test.com", password: "password123"})
        |> json_response(200)

      conn2 =
        build_conn()
        |> put_req_header("authorization", "Bearer #{jwt}")
        |> get("/tags")

      assert json_response(conn2, 200)
    end

    test "JWT from login can authenticate API requests", %{conn: conn} do
      post(conn, "/users/register", %{email: "jwt2@test.com", password: "password123"})

      %{"token" => jwt} =
        conn
        |> post("/users/login", %{email: "jwt2@test.com", password: "password123"})
        |> json_response(200)

      conn2 =
        build_conn()
        |> put_req_header("authorization", "Bearer #{jwt}")
        |> get("/tags")

      assert json_response(conn2, 200)
    end
  end
end
