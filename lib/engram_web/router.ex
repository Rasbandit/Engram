defmodule EngramWeb.Router do
  use EngramWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Public endpoints (no auth required)
  scope "/", EngramWeb do
    pipe_through :api
    get "/health", HealthController, :index
  end

  # Authenticated API endpoints
  scope "/", EngramWeb do
    pipe_through [:api, EngramWeb.Plugs.Auth]
  end
end
