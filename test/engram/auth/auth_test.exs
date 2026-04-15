defmodule Engram.AuthTest do
  use ExUnit.Case, async: true

  describe "provider/0" do
    test "returns Local provider by default" do
      prev = Application.get_env(:engram, :auth_provider)
      Application.put_env(:engram, :auth_provider, :local)

      assert Engram.Auth.provider() == Engram.Auth.Providers.Local

      if prev, do: Application.put_env(:engram, :auth_provider, prev),
        else: Application.delete_env(:engram, :auth_provider)
    end

    test "returns Clerk provider when configured" do
      prev = Application.get_env(:engram, :auth_provider)
      Application.put_env(:engram, :auth_provider, :clerk)

      assert Engram.Auth.provider() == Engram.Auth.Providers.Clerk

      Application.put_env(:engram, :auth_provider, prev || :local)
    end
  end

  describe "supports_credentials?/0" do
    @tag :skip
    test "returns true for local provider" do
      prev = Application.get_env(:engram, :auth_provider)
      Application.put_env(:engram, :auth_provider, :local)

      assert Engram.Auth.supports_credentials?() == true

      if prev, do: Application.put_env(:engram, :auth_provider, prev),
        else: Application.delete_env(:engram, :auth_provider)
    end
  end
end
