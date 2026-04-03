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

    # Notes CRUD
    post "/notes", NotesController, :upsert
    get "/notes/changes", NotesController, :changes
    get "/notes/*path", NotesController, :show
    delete "/notes/*path", NotesController, :delete

    # Metadata
    get "/tags", TagsController, :index
    get "/folders", FoldersController, :index

    # Search
    post "/search", SearchController, :search
  end
end
