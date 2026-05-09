defmodule Engram.Crypto.KeyProviderBehaviourTest do
  use ExUnit.Case, async: true

  alias Engram.Crypto.KeyProvider

  test "rotate_dek/2 is a behaviour callback" do
    callbacks = KeyProvider.behaviour_info(:callbacks)
    assert {:rotate_dek, 2} in callbacks
  end
end
