defmodule EngramWeb.Router do
  use EngramWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug :put_secure_browser_headers, %{
      "x-content-type-options" => "nosniff",
      "x-frame-options" => "DENY"
    }
  end

  # Public endpoints (no auth required)
  scope "/", EngramWeb do
    pipe_through :api
    get "/health", HealthController, :index
    get "/health/deep", HealthController, :deep
    post "/users/register", AuthController, :register
    post "/users/login", AuthController, :login
  end

  # Authenticated API endpoints
  scope "/", EngramWeb do
    pipe_through [:api, EngramWeb.Plugs.Auth]

    # Notes CRUD
    post "/notes/rename", NotesController, :rename
    post "/notes/append", NotesController, :append
    post "/notes", NotesController, :upsert
    get "/notes/changes", NotesController, :changes
    get "/notes/*path", NotesController, :show
    delete "/notes/*path", NotesController, :delete

    # Metadata
    get "/tags", TagsController, :index
    get "/folders/list", FoldersController, :list
    post "/folders/rename", FoldersController, :rename
    get "/folders", FoldersController, :index

    # Search
    post "/search", SearchController, :search

    # Sync
    get "/sync/manifest", SyncController, :manifest

    # User info
    get "/user/storage", StorageController, :index
    get "/me", UsersController, :me

    # API key management
    post "/api-keys", AuthController, :create_api_key
    delete "/api-keys/:id", AuthController, :revoke_api_key

    # Attachments
    post "/attachments", AttachmentsController, :upload
    get "/attachments/changes", AttachmentsController, :changes
    get "/attachments/*path", AttachmentsController, :show
    delete "/attachments/*path", AttachmentsController, :delete

    # Remote logging
    get "/logs", LogsController, :index
    post "/logs", LogsController, :ingest

    # MCP endpoint (JSON-RPC 2.0 over HTTP POST)
    post "/mcp", McpController, :handle
  end
end
