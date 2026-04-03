defmodule EngramWeb.Router do
  use EngramWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", EngramWeb do
    pipe_through :api
  end
end
