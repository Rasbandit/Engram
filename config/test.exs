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

# Use mock embedder in tests — never hits Voyage AI
config :engram, :embedder, Engram.MockEmbedder

# Disable Oban queues/plugins in test — jobs must be triggered explicitly via perform_job/2
# Use Oban.Testing.with_testing_mode(:inline, fn -> ... end) in tests that need inline execution
config :engram, Oban, testing: :manual

# JWT signing secret (Joken)
config :joken, default_signer: "test-jwt-secret"

# joken_jwks: use Erlang's built-in httpc adapter (no hackney required in tests)
config :tesla, JokenJwks.HttpFetcher, adapter: Tesla.Adapter.Httpc

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Clerk auth — disabled by default in tests.
# Individual tests that need Clerk start their own ClerkStrategy via start_supervised!
# and set these values in setup blocks.
config :engram, :clerk_jwks_url, nil
config :engram, :clerk_issuer, nil

# Stripe — disabled in tests, use Mox
config :stripity_stripe, api_key: "sk_test_fake"
config :engram, :stripe_webhook_secret, "whsec_test_fake"
config :engram, :stripe_starter_price_id, "price_starter_test"
config :engram, :stripe_pro_price_id, "price_pro_test"
