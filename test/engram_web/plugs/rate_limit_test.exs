defmodule EngramWeb.Plugs.RateLimitTest do
  use EngramWeb.ConnCase, async: false

  # Restore the high rate-limit ceiling after all tests in this module finish.
  setup_all do
    on_exit(fn ->
      Application.put_env(:engram, :rate_limit_override, 10_000)
    end)

    :ok
  end

  @test_limit 3

  setup do
    Application.put_env(:engram, :rate_limit_override, @test_limit)

    Hammer.delete_buckets("/api/auth/device:127.0.0.1")
    Hammer.delete_buckets("/api/auth/device/token:127.0.0.1")
    :ok
  end

  describe "rate limiting on device flow start" do
    test "allows requests under the limit" do
      conn = build_conn()
      conn = post(conn, "/api/auth/device", %{client_id: "test_client"})
      assert conn.status == 200
    end

    test "spoofing x-forwarded-for does not bypass the rate limit" do
      for i <- 1..(@test_limit + 1) do
        build_conn()
        |> put_req_header("x-forwarded-for", "10.0.0.#{i}")
        |> post("/api/auth/device", %{client_id: "test_client"})
      end

      conn =
        build_conn()
        |> put_req_header("x-forwarded-for", "10.0.0.99")
        |> post("/api/auth/device", %{client_id: "test_client"})

      assert conn.status == 429
    end

    test "returns 429 after exceeding limit" do
      for _ <- 1..(@test_limit + 1) do
        build_conn() |> post("/api/auth/device", %{client_id: "test_client"})
      end

      conn = build_conn() |> post("/api/auth/device", %{client_id: "test_client"})
      assert conn.status == 429
      assert json_response(conn, 429)["error"] == "rate_limited"
    end
  end

  describe "rate limiting on device token poll" do
    test "returns 429 after exceeding limit on token poll" do
      for _ <- 1..(@test_limit + 1) do
        build_conn() |> post("/api/auth/device/token", %{device_code: "fake_code"})
      end

      conn = build_conn() |> post("/api/auth/device/token", %{device_code: "fake_code"})
      assert conn.status == 429
    end
  end

  describe "rate limit buckets are per-path" do
    test "exhausting device start limit does not affect token poll" do
      for _ <- 1..(@test_limit + 1) do
        build_conn() |> post("/api/auth/device", %{client_id: "test_client"})
      end

      # token poll has its own bucket — should not be 429
      conn = build_conn() |> post("/api/auth/device/token", %{device_code: "fake_code"})
      refute conn.status == 429
    end
  end
end
