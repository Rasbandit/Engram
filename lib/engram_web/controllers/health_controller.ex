defmodule EngramWeb.HealthController do
  use EngramWeb, :controller

  def index(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
