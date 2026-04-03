defmodule Engram.Token do
  use Joken.Config

  @impl true
  def token_config do
    default_claims(default_exp: 7 * 24 * 3600)
  end
end
