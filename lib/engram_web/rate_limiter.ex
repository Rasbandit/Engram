defmodule EngramWeb.RateLimiter do
  @moduledoc """
  In-memory rate limiter used by the rate-limit plugs.

  Hammer v7 requires each app to define its own limiter module and start
  it under a supervisor; the global `config :hammer` block from v6 no
  longer exists. Started from `Engram.Application` with `clean_period`
  controlling how often expired buckets are swept.

  Backed by ETS — single-node only, fine for our deployment shape.
  Switching to `:atomic` or a distributed backend later only requires
  changing this module.
  """

  use Hammer, backend: :ets

  @doc """
  Wipe every bucket. Tests call this in `setup` to ensure each test
  starts at zero — replaces v6's `Hammer.delete_buckets/1`, which is
  gone in v7. Production code must not call this; it nukes shared rate-
  limit state for every key in the table.
  """
  if Mix.env() == :test do
    def reset_buckets! do
      :ets.delete_all_objects(__MODULE__)
    end
  end
end
