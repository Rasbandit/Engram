defmodule EngramWeb.Router do
  use EngramWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Public endpoints (no auth required)
  scope "/", EngramWeb do
    pipe_through :api
    get "/health", HealthController, :index
    post "/users/register", AuthController, :register
    post "/users/login", AuthController, :login
  end

  # Authenticated API endpoints
  scope "/", EngramWeb do
    pipe_through [:api, EngramWeb.Plugs.Auth]

    # Notes CRUD
    post "/notes/rename", NotesController, :rename
    post "/notes", NotesController, :upsert
    get "/notes/changes", NotesController, :changes
    get "/notes/*path", NotesController, :show
    delete "/notes/*path", NotesController, :delete

    # Metadata
    get "/tags", TagsController, :index
    get "/folders", FoldersController, :index

    # Search
    post "/search", SearchController, :search

    # Current user (for WebSocket channel topic)
    get "/me", UsersController, :me

    # API key management
    post "/api-keys", AuthController, :create_api_key
    delete "/api-keys/:id", AuthController, :revoke_api_key

    # Remote logging stub (plugin pushes logs here)
    post "/logs", LogsController, :ingest

    # MCP endpoint (JSON-RPC 2.0 over HTTP POST)
    post "/mcp", McpController, :handle
  end
end
