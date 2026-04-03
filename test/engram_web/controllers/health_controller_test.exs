defmodule EngramWeb.HealthControllerTest do
  use EngramWeb.ConnCase, async: true

  test "GET /health returns 200 with status ok", %{conn: conn} do
    conn = get(conn, "/health")
    assert json_response(conn, 200) == %{"status" => "ok"}
  end

  describe "GET /health/deep" do
    test "returns status and checks map", %{conn: conn} do
      conn = get(conn, "/health/deep")
      body = json_response(conn, conn.status)

      assert body["status"] in ["ok", "degraded"]
      assert is_map(body["checks"])
      assert Map.has_key?(body["checks"], "postgres")
      assert Map.has_key?(body["checks"], "qdrant")
    end

    test "postgres check is ok when DB is running", %{conn: conn} do
      conn = get(conn, "/health/deep")
      body = json_response(conn, conn.status)

      assert body["checks"]["postgres"] == "ok"
    end
  end
end
