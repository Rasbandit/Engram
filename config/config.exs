# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :engram,
  ecto_repos: [Engram.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :engram, EngramWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: EngramWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Engram.PubSub,
  live_view: [signing_salt: "tdOwl/mL"]

# Hammer rate limiting (ETS backend)
config :hammer,
  backend: {Hammer.Backend.ETS, [
    expiry_ms: 60_000 * 60,         # 1 hour bucket expiry
    cleanup_interval_ms: 60_000 * 2  # cleanup every 2 min
  ]}

# Oban job queue (per-env overrides in dev/test/prod configs)
config :engram, Oban,
  engine: Oban.Engines.Basic,
  repo: Engram.Repo,
  queues: [embed: 5, reindex: 1, maintenance: 2],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 7 * 24 * 3600},
    Oban.Plugins.Lifeline
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
