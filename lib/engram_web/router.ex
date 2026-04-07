defmodule EngramWeb.Router do
  use EngramWeb, :router

  pipeline :api do
    plug :accepts, ["json"]

    plug :put_secure_browser_headers, %{
      "x-content-type-options" => "nosniff",
      "x-frame-options" => "DENY"
    }
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :put_secure_browser_headers
  end

  # Stripe webhooks — no auth, raw body for signature verification
  scope "/webhooks", EngramWeb do
    pipe_through :api

    post "/stripe", WebhookController, :stripe
  end

  # All API routes under /api prefix
  scope "/api", EngramWeb do
    # Public endpoints (no auth required)
    pipe_through :api
    get "/health", HealthController, :index
    get "/health/deep", HealthController, :deep
    post "/users/register", AuthController, :register
    post "/users/login", AuthController, :login
  end

  # User-scoped authenticated endpoints (no vault context needed)
  scope "/api", EngramWeb do
    pipe_through [:api, EngramWeb.Plugs.Auth]

    # User info
    get "/user/storage", StorageController, :index
    get "/me", UsersController, :me

    # API key management
    post "/api-keys", AuthController, :create_api_key
    delete "/api-keys/:id", AuthController, :revoke_api_key

    # Vault management (user-level, not vault-scoped)
    get "/vaults", VaultsController, :index
    post "/vaults", VaultsController, :create
    get "/vaults/:id", VaultsController, :show
    patch "/vaults/:id", VaultsController, :update
    delete "/vaults/:id", VaultsController, :delete

    # Billing
    get "/billing/status", BillingController, :status
    post "/billing/checkout-session", BillingController, :create_checkout
    get "/billing/portal", BillingController, :customer_portal
  end

  # Vault-scoped authenticated endpoints (VaultPlug resolves current_vault)
  scope "/api", EngramWeb do
    pipe_through [:api, EngramWeb.Plugs.Auth, EngramWeb.Plugs.VaultPlug]

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

    # Attachments
    post "/attachments", AttachmentsController, :upload
    get "/attachments/changes", AttachmentsController, :changes
    get "/attachments/*path", AttachmentsController, :show
    delete "/attachments/*path", AttachmentsController, :delete

    # Remote logging
    get "/logs", LogsController, :index
    post "/logs", LogsController, :ingest

    # Embedding status
    get "/embed-status", EmbedStatusController, :index

    # MCP endpoint (JSON-RPC 2.0 over HTTP POST)
    post "/mcp", McpController, :handle
  end

  # Marketing pages — server-rendered HTML, before SPA catch-all
  scope "/", EngramWeb do
    pipe_through :browser

    get "/", MarketingController, :index
    get "/pricing", MarketingController, :pricing
    get "/docs", MarketingController, :docs
  end

  # SPA fallback — serves React app for all /app and /share routes.
  # Plug.Static in endpoint.ex serves actual asset files first;
  # only non-file requests reach these catch-all routes.
  scope "/", EngramWeb do
    get "/app", SpaController, :index
    get "/app/*path", SpaController, :index
    get "/share/*path", SpaController, :index
  end
end
