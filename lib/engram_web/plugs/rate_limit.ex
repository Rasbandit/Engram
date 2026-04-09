defmodule EngramWeb.Plugs.RateLimit do
  @moduledoc """
  Configurable rate-limiting plug backed by Hammer.
  Usage: `plug EngramWeb.Plugs.RateLimit, limit: 10, period: 60_000`
  """

  import Plug.Conn

  # Bake the build env into the module at compile time.
  # This ensures :rate_limit_override is structurally impossible in non-test builds.
  @build_env Application.compile_env(:engram, :env, :prod)
  @is_test_build @build_env == :test

  def init(opts) do
    %{
      limit: Keyword.fetch!(opts, :limit),
      period: Keyword.fetch!(opts, :period)
    }
  end

  def call(conn, %{limit: limit, period: period}) do
    # Allow test env to raise the limit without touching production config.
    # :rate_limit_override is set in config/test.exs to avoid false 429s
    # when many tests share the same remote_ip (127.0.0.1).
    # @is_test_build is evaluated at compile time, so override is structurally
    # impossible in non-test builds. Use || to handle nil, which allows tests
    # to reset the override to nil and fall back to the plug's configured limit.
    effective_limit =
      if @is_test_build do
        Application.get_env(:engram, :rate_limit_override) || limit
      else
        limit
      end

    key = rate_limit_key(conn)

    case Hammer.check_rate(key, period, effective_limit) do
      {:allow, _count} ->
        conn

      {:deny, _limit} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(429, Jason.encode!(%{error: "rate_limited"}))
        |> halt()
    end
  end

  defp rate_limit_key(conn) do
    # Use conn.remote_ip — this is the IP Plug resolved from the actual TCP
    # connection (or from a trusted proxy via Plug.RewriteOn if configured).
    # Do NOT trust x-forwarded-for directly: it is client-controlled and
    # trivially spoofable, making the rate limit bypassable.
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()
    "#{conn.request_path}:#{ip}"
  end
end
