defmodule EngramWeb.MarketingControllerTest do
  use EngramWeb.ConnCase, async: true

  defp html_conn(%{conn: conn}) do
    {:ok, conn: put_req_header(conn, "accept", "text/html")}
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
end
