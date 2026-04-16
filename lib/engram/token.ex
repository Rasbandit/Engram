defmodule Engram.Token do
  use Joken.Config

  add_hook(Joken.Hooks.RequiredClaims, ["iss", "aud"])

  @impl true
  def token_config do
    # skip: [:iss, :aud] prevents Joken from auto-generating default iss/aud claims
    # that would conflict with our explicit add_claim registrations below.
    # Without skip, Joken would try to register its own iss/aud generators and the
    # duplicate key definitions would raise a runtime error.
    default_claims(default_exp: 15 * 60, skip: [:iss, :aud])
    |> add_claim("iss", fn -> "engram" end, &(&1 == "engram"))
    |> add_claim("aud", fn -> "engram" end, &(&1 == "engram"))
  end
end
