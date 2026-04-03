import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :engram, Engram.Repo,
  username: "engram",
  password: "engram",
  hostname: "localhost",
  database: "engram_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :engram, EngramWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "JBTH+ZYHTDIRrr+N6s2ooO4ckeuJvolFrrF3N5KuC8vU75YeOgmr2beGWxrZq3Qi",
  server: false

# Disable Oban queues/plugins in test — use Oban.Testing helpers instead
config :engram, Oban, testing: :inline

# JWT signing secret (Joken)
config :joken, default_signer: "test-jwt-secret"

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
