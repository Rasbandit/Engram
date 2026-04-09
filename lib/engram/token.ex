defmodule Engram.Token do
  use Joken.Config

  add_hook(Joken.Hooks.RequiredClaims, ["iss", "aud"])

  @impl true
  def token_config do
    default_claims(default_exp: 7 * 24 * 3600, skip: [:iss, :aud])
    |> add_claim("iss", fn -> "engram" end, &(&1 == "engram"))
    |> add_claim("aud", fn -> "engram" end, &(&1 == "engram"))
  end
end
