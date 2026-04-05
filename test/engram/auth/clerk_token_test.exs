defmodule Engram.Auth.ClerkTokenTest do
  use Engram.DataCase, async: false

  alias Engram.Auth.ClerkToken

  setup do
    {bypass, jwks_url} = Engram.ClerkHelpers.start_jwks_server()

    # Configure Clerk settings for this test
    prev_url = Application.get_env(:engram, :clerk_jwks_url)
    prev_issuer = Application.get_env(:engram, :clerk_issuer)

    Application.put_env(:engram, :clerk_jwks_url, jwks_url)
    Application.put_env(:engram, :clerk_issuer, Engram.ClerkHelpers.issuer())

    # Start the ClerkStrategy GenServer pointed at our Bypass.
    # first_fetch_sync: true ensures JWKS is in ETS before any test runs.
    start_supervised!({Engram.Auth.ClerkStrategy, time_interval: 60_000, first_fetch_sync: true})

    on_exit(fn ->
      if prev_url,
        do: Application.put_env(:engram, :clerk_jwks_url, prev_url),
        else: Application.delete_env(:engram, :clerk_jwks_url)

      if prev_issuer,
        do: Application.put_env(:engram, :clerk_issuer, prev_issuer),
        else: Application.delete_env(:engram, :clerk_issuer)
    end)

    %{bypass: bypass}
  end

  test "verifies a valid Clerk JWT" do
    claims = Engram.ClerkHelpers.clerk_claims("clerk_user_123")
    token = Engram.ClerkHelpers.sign_clerk_jwt(claims)

    assert {:ok, verified} = ClerkToken.verify_clerk_jwt(token)
    assert verified["sub"] == "clerk_user_123"
  end

  test "rejects an expired JWT" do
    claims =
      Engram.ClerkHelpers.clerk_claims("clerk_user_exp", exp: :os.system_time(:second) - 60)

    token = Engram.ClerkHelpers.sign_clerk_jwt(claims)

    assert {:error, _reason} = ClerkToken.verify_clerk_jwt(token)
  end

  test "rejects JWT with wrong issuer" do
    claims =
      Engram.ClerkHelpers.clerk_claims("clerk_user_iss", issuer: "https://evil.example.com")

    token = Engram.ClerkHelpers.sign_clerk_jwt(claims)

    assert {:error, _reason} = ClerkToken.verify_clerk_jwt(token)
  end

  test "rejects a completely invalid token" do
    assert {:error, _reason} = ClerkToken.verify_clerk_jwt("not.a.jwt")
  end

  test "rejects a JWT signed with a different key" do
    # Sign with a freshly generated key (not in our JWKS)
    other_jwk = JOSE.JWK.generate_key({:rsa, 2048})
    jws = %{"alg" => "RS256", "kid" => "unknown-key-id"}
    claims = Engram.ClerkHelpers.clerk_claims("clerk_user_bad_key")

    {_alg, token} =
      JOSE.JWK.sign(Jason.encode!(claims), jws, other_jwk)
      |> JOSE.JWS.compact()

    assert {:error, _reason} = ClerkToken.verify_clerk_jwt(token)
  end
end
