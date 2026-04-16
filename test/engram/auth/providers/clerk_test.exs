defmodule Engram.Auth.Providers.ClerkTest do
  use Engram.DataCase, async: false

  alias Engram.Auth.Providers.Clerk

  setup do
    {_bypass, jwks_url} = Engram.ClerkHelpers.start_jwks_server()

    prev_url = Application.get_env(:engram, :clerk_jwks_url)
    prev_issuer = Application.get_env(:engram, :clerk_issuer)

    Application.put_env(:engram, :clerk_jwks_url, jwks_url)
    Application.put_env(:engram, :clerk_issuer, Engram.ClerkHelpers.issuer())

    start_supervised!({Engram.Auth.ClerkStrategy, time_interval: 60_000, first_fetch_sync: true})

    on_exit(fn ->
      if prev_url,
        do: Application.put_env(:engram, :clerk_jwks_url, prev_url),
        else: Application.delete_env(:engram, :clerk_jwks_url)

      if prev_issuer,
        do: Application.put_env(:engram, :clerk_issuer, prev_issuer),
        else: Application.delete_env(:engram, :clerk_issuer)
    end)

    :ok
  end

  describe "verify_token/1" do
    test "returns external_id and email from valid Clerk JWT" do
      claims = Engram.ClerkHelpers.clerk_claims("clerk_user_abc", email: "clerk@example.com")
      token = Engram.ClerkHelpers.sign_clerk_jwt(claims)

      assert {:ok, %{external_id: "clerk_user_abc", email: "clerk@example.com"}} =
               Clerk.verify_token(token)
    end

    @tag capture_log: true
    test "rejects expired JWT" do
      claims = Engram.ClerkHelpers.clerk_claims("clerk_exp", exp: :os.system_time(:second) - 60)
      token = Engram.ClerkHelpers.sign_clerk_jwt(claims)

      assert {:error, _reason} = Clerk.verify_token(token)
    end

    @tag capture_log: true
    test "rejects invalid token" do
      assert {:error, _reason} = Clerk.verify_token("garbage")
    end
  end

  describe "supports_credentials?/0" do
    test "returns false" do
      assert Clerk.supports_credentials?() == false
    end
  end

  describe "authenticate_credentials/2" do
    test "returns not_supported" do
      assert {:error, :not_supported} = Clerk.authenticate_credentials("a@b.com", "pass")
    end
  end

  describe "register_user/3" do
    test "returns not_supported" do
      assert {:error, :not_supported} = Clerk.register_user("a@b.com", "pass", %{})
    end
  end
end
