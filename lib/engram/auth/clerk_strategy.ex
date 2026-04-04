defmodule Engram.Auth.ClerkStrategy do
  @moduledoc """
  JokenJwks strategy for fetching Clerk's JWKS public keys.

  Started as a child of the application supervisor when `CLERK_JWKS_URL` is set.
  Fetches keys from Clerk's JWKS endpoint, caches them in ETS, and refreshes
  on cache miss (unknown kid) or on a time interval.
  """

  use JokenJwks.DefaultStrategyTemplate

  def init_opts(opts) do
    url =
      Application.get_env(:engram, :clerk_jwks_url) ||
        raise "Missing :clerk_jwks_url config (set CLERK_JWKS_URL env var)"

    Keyword.merge(opts, jwks_url: url)
  end
end
