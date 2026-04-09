defmodule EngramWeb.Plugs.RateLimitTest do
  use EngramWeb.ConnCase, async: false

  # Restore the high rate-limit ceiling after all tests in this module finish.
  # Using setup_all avoids the on_exit race where a per-test on_exit from
  # test N fires during test N+1 and restores the override mid-execution.
  setup_all do
    on_exit(fn ->
      Application.put_env(:engram, :rate_limit_override, 10_000)
    end)

    :ok
  end

  # Use a low limit (3) to minimize HTTP requests needed to trigger 429.
  # The real plug limit is 10; we override to 3 here to keep tests fast
  # while still validating the rate-limiting behaviour.
  @test_limit 3

  setup do
    # Override to a low limit so we only need 4 requests to trigger 429.
    Application.put_env(:engram, :rate_limit_override, @test_limit)

    # Reset Hammer counters for auth paths between tests to prevent bleed.
    # In tests, build_conn() resolves remote_ip to 127.0.0.1, so the full
    # rate-limit key matches these strings exactly.
    Hammer.delete_buckets("/api/users/login:127.0.0.1")
    Hammer.delete_buckets("/api/users/register:127.0.0.1")
    :ok
  end

  describe "rate limiting on login" do
    test "allows requests under the limit" do
      conn = build_conn()
      conn = post(conn, "/api/users/login", %{email: "x@x.com", password: "wrong"})
      # Should get 401 (bad creds), not 429
      assert conn.status == 401
    end

    test "spoofing x-forwarded-for does not bypass the rate limit" do
      # Send @test_limit+1 requests each with a different spoofed IP.
      # If plug keys on x-forwarded-for, each would look like a fresh IP and limit never triggers.
      # Plug must key on conn.remote_ip (127.0.0.1 in test) instead.
      for i <- 1..(@test_limit + 1) do
        build_conn()
        |> put_req_header("x-forwarded-for", "10.0.0.#{i}")
        |> post("/api/users/login", %{email: "x@x.com", password: "wrong"})
      end

      conn =
        build_conn()
        |> put_req_header("x-forwarded-for", "10.0.0.99")
        |> post("/api/users/login", %{email: "x@x.com", password: "wrong"})

      assert conn.status == 429
    end

    test "returns 429 after exceeding limit" do
      for _ <- 1..(@test_limit + 1) do
        build_conn() |> post("/api/users/login", %{email: "x@x.com", password: "wrong"})
      end

      conn = build_conn() |> post("/api/users/login", %{email: "x@x.com", password: "wrong"})
      assert conn.status == 429
      assert json_response(conn, 429)["error"] == "rate_limited"
    end
  end

  describe "rate limiting on register" do
    test "returns 429 after exceeding limit on register" do
      for _ <- 1..(@test_limit + 1) do
        build_conn() |> post("/api/users/register", %{email: "x@x.com", password: "wrong"})
      end

      conn = build_conn() |> post("/api/users/register", %{email: "x@x.com", password: "wrong"})
      assert conn.status == 429
    end
  end

  describe "rate limit buckets are per-path" do
    test "exhausting login limit does not affect register" do
      for _ <- 1..(@test_limit + 1) do
        build_conn() |> post("/api/users/login", %{email: "x@x.com", password: "wrong"})
      end

      # register has its own bucket — should not be 429
      conn = build_conn() |> post("/api/users/register", %{email: "new@x.com", password: "Pass123!"})
      refute conn.status == 429
    end
  end
end
