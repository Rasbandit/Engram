defmodule Engram.AuthTest do
  # async: false — tests mutate global Application config
  use ExUnit.Case, async: false

  setup do
    prev = Application.get_env(:engram, :auth_provider)
    on_exit(fn -> Application.put_env(:engram, :auth_provider, prev || :local) end)
    %{prev: prev}
  end

  describe "provider/0" do
    test "returns Local provider by default" do
      Application.put_env(:engram, :auth_provider, :local)
      assert Engram.Auth.provider() == Engram.Auth.Providers.Local
    end

    test "returns Clerk provider when configured" do
      Application.put_env(:engram, :auth_provider, :clerk)
      assert Engram.Auth.provider() == Engram.Auth.Providers.Clerk
    end

    test "raises on invalid provider config" do
      Application.put_env(:engram, :auth_provider, :invalid)

      assert_raise RuntimeError, ~r/Invalid :auth_provider config/, fn ->
        Engram.Auth.provider()
      end
    end
  end

  describe "supports_credentials?/0" do
    test "returns true for local provider" do
      Application.put_env(:engram, :auth_provider, :local)
      assert Engram.Auth.supports_credentials?() == true
    end

    test "returns false for clerk provider" do
      Application.put_env(:engram, :auth_provider, :clerk)
      assert Engram.Auth.supports_credentials?() == false
    end
  end
end
