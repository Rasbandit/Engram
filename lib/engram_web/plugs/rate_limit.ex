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
    effective_limit = effective_limit(limit)

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

  # Compile-time branch: test builds use :rate_limit_override from config/test.exs.
  # Non-test builds (dev/prod) use :rate_limit_auth_override ONLY when CI=true.
  # Production deploys never set CI=true, so this is unreachable in prod.
  if @is_test_build do
    defp effective_limit(default) do
      Application.get_env(:engram, :rate_limit_override) || default
    end
  else
    defp effective_limit(default) do
      if System.get_env("CI") == "true" do
        Application.get_env(:engram, :rate_limit_auth_override) || default
      else
        default
      end
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
