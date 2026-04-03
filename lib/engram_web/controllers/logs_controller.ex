defmodule EngramWeb.LogsController do
  use EngramWeb, :controller

  alias Engram.Logs

  def ingest(conn, %{"logs" => logs}) when is_list(logs) do
    user = conn.assigns.current_user
    {:ok, count} = Logs.insert_logs(user, logs)
    json(conn, %{ok: true, count: count})
  end

  def ingest(conn, _params), do: json(conn, %{ok: true, count: 0})

  def index(conn, params) do
    user = conn.assigns.current_user

    opts =
      []
      |> maybe_add(:level, params["level"])
      |> maybe_add(:category, params["category"])
      |> maybe_add_since(params["since"])
      |> maybe_add_limit(params["limit"])

    {:ok, logs} = Logs.list_logs(user, opts)

    json(conn, %{
      logs: Enum.map(logs, &serialize_log/1)
    })
  end

  defp serialize_log(log) do
    %{
      id: log.id,
      ts: log.ts,
      level: log.level,
      category: log.category,
      message: log.message,
      stack: log.stack,
      plugin_version: log.plugin_version,
      platform: log.platform,
      created_at: log.inserted_at
    }
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_add_since(opts, nil), do: opts

  defp maybe_add_since(opts, since) do
    case DateTime.from_iso8601(since) do
      {:ok, dt, _} -> Keyword.put(opts, :since, dt)
      _ -> opts
    end
  end

  defp maybe_add_limit(opts, nil), do: opts

  defp maybe_add_limit(opts, limit) do
    case Integer.parse(limit) do
      {n, ""} -> Keyword.put(opts, :limit, n)
      _ -> opts
    end
  end
end
