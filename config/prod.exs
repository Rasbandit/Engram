import Config

# TLS is terminated at the edge (Fly.io proxy / nginx) — no force_ssl in app.
# Do not print debug messages in production
config :logger, level: :info

# WebSocket origin check — allowlist replaces the default false.
# PHX_HOST is set at build time on Fly.io. Obsidian's app:// scheme
# is required for the desktop plugin to connect over WebSocket.
config :engram,
       :websocket_check_origin,
       ["https://" <> System.fetch_env!("PHX_HOST"), "app://obsidian.md"]

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
