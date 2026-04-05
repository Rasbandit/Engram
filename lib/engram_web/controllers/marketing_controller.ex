defmodule EngramWeb.MarketingController do
  use EngramWeb, :controller

  plug :put_layout, html: {EngramWeb.Layouts, :marketing}

  def index(conn, _params) do
    render(conn, :index)
  end

  def pricing(conn, _params) do
    render(conn, :pricing)
  end
end
