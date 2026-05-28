defmodule EngramWeb.McpTransportTest do
  use EngramWeb.ConnCase, async: true

  # The MCP endpoint is POST-only JSON-RPC. Streamable-HTTP clients open a
  # GET on the endpoint for a server→client SSE stream (and DELETE to end a
  # session). We offer neither, so the spec-correct answer is 405 + Allow —
  # not a 404, which clients treat as a missing endpoint and abort.
  describe "unsupported transport methods on /api/mcp" do
    test "GET returns 405 with Allow: POST (no auth required)", %{conn: conn} do
      conn = get(conn, "/api/mcp")
      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["POST"]
    end

    test "DELETE returns 405 with Allow: POST (no auth required)", %{conn: conn} do
      conn = delete(conn, "/api/mcp")
      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["POST"]
    end
  end
end
