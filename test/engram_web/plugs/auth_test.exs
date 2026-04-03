defmodule EngramWeb.Plugs.AuthTest do
  use EngramWeb.ConnCase, async: false

  alias Engram.Accounts
  alias EngramWeb.Plugs.Auth

  setup do
    {:ok, user} =
      Accounts.register_user(%{email: "plug@test.com", password: "password123"})

    {:ok, raw_key, _api_key} = Accounts.create_api_key(user, "test")
    jwt = Accounts.generate_jwt(user)

    %{user: user, raw_key: raw_key, jwt: jwt}
  end

  test "authenticates with valid API key", %{user: user, raw_key: raw_key} do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{raw_key}")
      |> Auth.call([])

    assert conn.assigns.current_user.id == user.id
    refute conn.halted
  end

  test "authenticates with valid JWT", %{user: user, jwt: jwt} do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{jwt}")
      |> Auth.call([])

    assert conn.assigns.current_user.id == user.id
    refute conn.halted
  end

  test "rejects missing auth header" do
    conn =
      build_conn()
      |> Auth.call([])

    assert conn.status == 401
    assert conn.halted
  end

  test "rejects invalid API key" do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer engram_invalid")
      |> Auth.call([])

    assert conn.status == 401
    assert conn.halted
  end

  test "rejects invalid JWT" do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer not.a.jwt")
      |> Auth.call([])

    assert conn.status == 401
    assert conn.halted
  end
end
