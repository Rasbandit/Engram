defmodule EngramWeb.SpaController do
  use EngramWeb, :controller

  def index(conn, _params) do
    index_path = Application.app_dir(:engram, "priv/static/app/index.html")

    conn
    |> put_resp_content_type("text/html")
    |> send_file(200, index_path)
  end
end
