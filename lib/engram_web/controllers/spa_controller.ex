defmodule EngramWeb.SpaController do
  use EngramWeb, :controller

  require Logger

  def index(conn, _params) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, injected_html())
  end

  defp injected_html do
    case :persistent_term.get({__MODULE__, :html}, nil) do
      nil ->
        html = build_injected_html()
        :persistent_term.put({__MODULE__, :html}, html)
        html

      cached ->
        cached
    end
  end

  defp build_injected_html do
    path = Application.app_dir(:engram, "priv/static/app/index.html")
    html = File.read!(path)
    result = String.replace(html, "</head>", config_script() <> "</head>", global: false)

    if html == result do
      Logger.error("Failed to inject runtime config: </head> not found in #{path}")
    end

    result
  end

  defp config_script do
    config = %{
      authProvider: to_string(Application.get_env(:engram, :auth_provider, :local)),
      clerkPublishableKey: Application.get_env(:engram, :clerk_publishable_key, "")
    }

    json =
      config
      |> Jason.encode!()
      |> String.replace("</", "<\\/")
      |> String.replace("<!--", "<\\!--")

    ~s[<script>window.__ENGRAM_CONFIG__=#{json};</script>]
  end
end
