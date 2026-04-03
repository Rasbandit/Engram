defmodule EngramWeb.LogsController do
  use EngramWeb, :controller

  require Logger

  def ingest(conn, %{"logs" => logs}) when is_list(logs) do
    Enum.each(logs, fn entry ->
      level = entry["level"] || "info"
      msg = "[plugin:#{entry["platform"]}] #{entry["category"]} — #{entry["message"]}"

      case level do
        "error" -> Logger.error(msg)
        "warn" -> Logger.warning(msg)
        _ -> Logger.info(msg)
      end
    end)

    json(conn, %{ok: true})
  end

  def ingest(conn, _params), do: json(conn, %{ok: true})
end
