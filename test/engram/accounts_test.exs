defmodule Engram.AccountsTest do
  use Engram.DataCase, async: true

  alias Engram.Accounts

  describe "register_user/1" do
    test "creates user with valid attrs" do
      assert {:ok, user} =
               Accounts.register_user(%{
                 email: "test@example.com",
                 password: "password123"
               })

      assert user.email == "test@example.com"
      assert user.password_hash != nil
    end

    test "rejects duplicate email" do
      Accounts.register_user(%{email: "dup@example.com", password: "password123"})

      assert {:error, changeset} =
               Accounts.register_user(%{email: "dup@example.com", password: "password123"})

      assert errors_on(changeset).email != nil
    end

    test "rejects short password" do
      assert {:error, changeset} =
               Accounts.register_user(%{email: "x@y.com", password: "short"})

      assert errors_on(changeset).password != nil
    end
  end

  describe "authenticate_user/2" do
    test "returns user with correct credentials" do
      {:ok, user} =
        Accounts.register_user(%{email: "auth@test.com", password: "password123"})

      assert {:ok, authed_user} = Accounts.authenticate_user("auth@test.com", "password123")
      assert authed_user.id == user.id
    end

    test "rejects wrong password" do
      Accounts.register_user(%{email: "auth2@test.com", password: "password123"})

      assert {:error, :invalid_credentials} =
               Accounts.authenticate_user("auth2@test.com", "wrong")
    end

    test "rejects unknown email" do
      assert {:error, :invalid_credentials} =
               Accounts.authenticate_user("nobody@test.com", "password123")
    end

    # Legacy password auth timing test — not meaningful with Clerk auth.
    # Also breaks with low Argon2 cost in test env (t_cost=1).
    # Remove when Argon2 is fully removed (see docs/context/TODO-remove-argon2.md).
    @tag :skip
    test "unknown email takes comparable time to wrong password (timing attack protection)" do
      Accounts.register_user(%{email: "timing@test.com", password: "password123"})

      # Wrong password (does real hash verification)
      {wrong_pw_time, _} =
        :timer.tc(fn ->
          Accounts.authenticate_user("timing@test.com", "wrongpassword")
        end)

      # Unknown email (should also do dummy hash work via no_user_verify)
      {unknown_time, _} =
        :timer.tc(fn ->
          Accounts.authenticate_user("nonexistent@test.com", "password123")
        end)

      # Argon2 hashing takes ~100-400ms. If unknown email skips hash work,
      # it'll be <10ms (just a DB query). Require at least 50% of real hash time.
      min_expected = div(wrong_pw_time, 2)

      assert unknown_time > min_expected,
             "unknown email took #{unknown_time}µs vs wrong password #{wrong_pw_time}µs — " <>
               "missing Argon2.no_user_verify/0"
    end
  end

  describe "API keys" do
    setup do
      {:ok, user} =
        Accounts.register_user(%{email: "apikey@test.com", password: "password123"})

      %{user: user}
    end

    test "create_api_key returns raw key with engram_ prefix", %{user: user} do
      assert {:ok, raw_key, api_key} = Accounts.create_api_key(user, "test key")
      assert String.starts_with?(raw_key, "engram_")
      assert api_key.name == "test key"
      assert api_key.user_id == user.id
    end

    test "validate_api_key finds key by hash", %{user: user} do
      {:ok, raw_key, _api_key} = Accounts.create_api_key(user, "validate test")
      assert {:ok, found_user, _api_key} = Accounts.validate_api_key(raw_key)
      assert found_user.id == user.id
    end

    test "validate_api_key rejects invalid key" do
      assert {:error, :invalid_key} = Accounts.validate_api_key("engram_bogus")
    end

    test "list_api_keys returns user's keys", %{user: user} do
      Accounts.create_api_key(user, "key1")
      Accounts.create_api_key(user, "key2")
      keys = Accounts.list_api_keys(user)
      assert length(keys) == 2
    end

    test "revoke_api_key deletes the key", %{user: user} do
      {:ok, _raw, api_key} = Accounts.create_api_key(user, "to revoke")
      assert :ok = Accounts.revoke_api_key(user, api_key.id)
      assert Accounts.list_api_keys(user) == []
    end
  end

  describe "find_or_create_by_clerk_id/2" do
    test "returns existing user when clerk_id matches" do
      {:ok, user} =
        Accounts.register_user(%{email: "existing@test.com", password: "password123"})

      # Manually set clerk_id (simulating a previous Clerk login)
      user
      |> Ecto.Changeset.change(%{clerk_id: "clerk_user_abc"})
      |> Engram.Repo.update!(skip_tenant_check: true)

      assert {:ok, found} =
               Accounts.find_or_create_by_clerk_id("clerk_user_abc", %{
                 email: "existing@test.com"
               })

      assert found.id == user.id
      assert found.clerk_id == "clerk_user_abc"
    end

    test "links clerk_id to existing user matched by email" do
      {:ok, user} =
        Accounts.register_user(%{email: "link@test.com", password: "password123"})

      assert {:ok, linked} =
               Accounts.find_or_create_by_clerk_id("clerk_user_link", %{
                 email: "link@test.com"
               })

      assert linked.id == user.id
      assert linked.clerk_id == "clerk_user_link"
    end

    test "creates new user when no clerk_id or email match" do
      assert {:ok, created} =
               Accounts.find_or_create_by_clerk_id("clerk_user_new", %{
                 email: "brand_new@test.com"
               })

      assert created.clerk_id == "clerk_user_new"
      assert created.email == "brand_new@test.com"
      assert created.password_hash == nil
    end

    test "returns existing clerk user even if email changed in Clerk" do
      {:ok, user} =
        Accounts.register_user(%{email: "old@test.com", password: "password123"})

      user
      |> Ecto.Changeset.change(%{clerk_id: "clerk_stable"})
      |> Engram.Repo.update!(skip_tenant_check: true)

      # Clerk now reports a different email, but clerk_id is the same
      assert {:ok, found} =
               Accounts.find_or_create_by_clerk_id("clerk_stable", %{
                 email: "new@test.com"
               })

      assert found.id == user.id
      # clerk_id lookup takes precedence — email is NOT updated
      assert found.email == "old@test.com"
    end
  end

  describe "JWT" do
    test "generate and verify token round-trip" do
      {:ok, user} =
        Accounts.register_user(%{email: "jwt@test.com", password: "password123"})

      token = Accounts.generate_jwt(user)
      assert {:ok, claims} = Accounts.verify_jwt(token)
      assert claims["user_id"] == user.id
    end

    test "rejects tampered token" do
      assert {:error, _reason} = Accounts.verify_jwt("garbage.token.here")
    end
  end
end
