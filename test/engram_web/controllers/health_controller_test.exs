defmodule EngramWeb.HealthControllerTest do
  use EngramWeb.ConnCase, async: true

  test "GET /health returns 200 with status ok", %{conn: conn} do
    conn = get(conn, "/health")
    assert json_response(conn, 200) == %{"status" => "ok"}
  end
end
