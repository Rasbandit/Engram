defmodule Engram.AccountsTest do
  use Engram.DataCase, async: false

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
      assert {:error, :invalid_credentials} = Accounts.authenticate_user("auth2@test.com", "wrong")
    end

    test "rejects unknown email" do
      assert {:error, :invalid_credentials} = Accounts.authenticate_user("nobody@test.com", "password123")
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
      assert {:ok, found_user} = Accounts.validate_api_key(raw_key)
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
