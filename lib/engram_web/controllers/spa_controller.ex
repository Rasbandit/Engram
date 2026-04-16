defmodule EngramWeb.SpaController do
  use EngramWeb, :controller

  def index(conn, _params) do
    path = Application.app_dir(:engram, "priv/static/app/index.html")
    html = File.read!(path)
    injected = String.replace(html, "</head>", config_script() <> "</head>", global: false)

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, injected)
  end

  defp config_script do
    config = %{
      authProvider: to_string(Application.get_env(:engram, :auth_provider, :local)),
      clerkPublishableKey: Application.get_env(:engram, :clerk_publishable_key, "")
    }

    json = config |> Jason.encode!() |> String.replace("</", "<\\/")
    ~s[<script>window.__ENGRAM_CONFIG__=#{json};</script>]
  end
end
