defmodule EngramWeb.MarketingControllerTest do
  use EngramWeb.ConnCase, async: true

  # First TCP congestion window ≈ 14KB. Marketing pages must fit
  # within this budget (gzipped) for single-RTT first paint.
  @max_gzipped_bytes 14_336

  defp html_conn(%{conn: conn}) do
    {:ok, conn: put_req_header(conn, "accept", "text/html")}
  end

  defp assert_within_14kb(body) do
    gzipped = :zlib.gzip(body)
    gzipped_size = byte_size(gzipped)

    assert gzipped_size <= @max_gzipped_bytes,
           "Page exceeds 14KB budget: #{gzipped_size} bytes gzipped (limit: #{@max_gzipped_bytes})"
  end

  describe "GET /" do
    setup :html_conn

    test "returns 200 with landing page content", %{conn: conn} do
      conn = get(conn, "/")
      body = html_response(conn, 200)

      assert body =~ "Your second brain, powered by AI"
      assert body =~ "Obsidian Sync"
      assert body =~ "Semantic Search"
      assert body =~ "MCP Integration"
      assert body =~ "Start Free Trial"
      assert_within_14kb(body)
    end

    test "includes marketing layout with nav and stylesheet", %{conn: conn} do
      conn = get(conn, "/")
      body = html_response(conn, 200)

      assert body =~ ~s(href="/css/marketing.css")
      assert body =~ ~s(href="/pricing")
      assert body =~ ~s(href="/docs")
      assert body =~ ~s(href="/app/sign-in")
      assert body =~ ~s(href="/app/sign-up")
    end
  end

  describe "GET /pricing" do
    setup :html_conn

    test "returns 200 with pricing tiers", %{conn: conn} do
      conn = get(conn, "/pricing")
      body = html_response(conn, 200)

      assert body =~ "Simple, honest pricing"
      assert body =~ "Starter"
      assert body =~ "Pro"
      assert body =~ "$5"
      assert body =~ "$10"
      assert_within_14kb(body)
    end

    test "shows feature details for both tiers", %{conn: conn} do
      conn = get(conn, "/pricing")
      body = html_response(conn, 200)

      assert body =~ "5 devices"
      assert body =~ "10 GB storage"
      assert body =~ "Unlimited devices"
      assert body =~ "50 GB storage"
      assert body =~ "Most Popular"
    end
  end

  describe "GET /docs" do
    setup :html_conn

    test "returns 200 with API documentation", %{conn: conn} do
      conn = get(conn, "/docs")
      body = html_response(conn, 200)

      assert body =~ "API Documentation"
      assert body =~ "Authentication"
      assert body =~ "engram_your_api_key"
      assert_within_14kb(body)
    end

    test "lists key endpoints", %{conn: conn} do
      conn = get(conn, "/docs")
      body = html_response(conn, 200)

      assert body =~ "/api/health"
      assert body =~ "/api/notes"
      assert body =~ "/api/search"
      assert body =~ "/api/mcp"
    end
  end

  describe "response headers" do
    setup :html_conn

    test "marketing pages return text/html content type", %{conn: conn} do
      for path <- ["/", "/pricing", "/docs"] do
        conn = get(conn, path)
        assert {"content-type", content_type} = List.keyfind(conn.resp_headers, "content-type", 0)
        assert content_type =~ "text/html"
      end
    end

    test "marketing pages include security headers", %{conn: conn} do
      conn = get(conn, "/")

      headers = Map.new(conn.resp_headers)
      assert Map.has_key?(headers, "x-content-type-options")
      assert Map.has_key?(headers, "content-security-policy")
      assert Map.has_key?(headers, "referrer-policy")
    end
  end

  describe "route isolation" do
    setup :html_conn

    test "API health endpoint still returns JSON, not HTML", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/api/health")

      assert json_response(conn, 200)["status"] == "ok"
    end

    test "unknown marketing paths do not match", %{conn: conn} do
      conn = get(conn, "/nonexistent")
      assert conn.status in [404, 406]
    end
  end

  describe "semantic HTML" do
    setup :html_conn

    test "landing page has proper document structure", %{conn: conn} do
      conn = get(conn, "/")
      body = html_response(conn, 200)

      assert body =~ "<!DOCTYPE html>"
      assert body =~ ~s(lang="en")
      assert body =~ "<header"
      assert body =~ "<main"
      assert body =~ "<footer"
      assert body =~ ~s(charset="utf-8")
      assert body =~ ~s(name="viewport")
    end
  end
end
