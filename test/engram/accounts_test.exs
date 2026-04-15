defmodule Engram.AccountsTest do
  use Engram.DataCase, async: true

  alias Engram.Accounts

  describe "API keys" do
    setup do
      user = insert(:user)
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

  describe "find_or_create_by_external_id/2" do
    test "returns existing user when external_id matches" do
      user = insert(:user, email: "existing@test.com")

      # Manually set external_id (simulating a previous Clerk login)
      user
      |> Ecto.Changeset.change(%{external_id: "clerk_user_abc"})
      |> Engram.Repo.update!(skip_tenant_check: true)

      assert {:ok, found} =
               Accounts.find_or_create_by_external_id("clerk_user_abc", %{
                 email: "existing@test.com"
               })

      assert found.id == user.id
      assert found.external_id == "clerk_user_abc"
    end

    test "links external_id to existing user matched by email" do
      user = insert(:user, email: "link@test.com")

      assert {:ok, linked} =
               Accounts.find_or_create_by_external_id("clerk_user_link", %{
                 email: "link@test.com"
               })

      assert linked.id == user.id
      assert linked.external_id == "clerk_user_link"
    end

    test "creates new user when no external_id or email match" do
      assert {:ok, created} =
               Accounts.find_or_create_by_external_id("clerk_user_new", %{
                 email: "brand_new@test.com"
               })

      assert created.external_id == "clerk_user_new"
      assert created.email == "brand_new@test.com"
    end

    test "returns existing user even if email changed in provider" do
      user = insert(:user, email: "old@test.com")

      user
      |> Ecto.Changeset.change(%{external_id: "clerk_stable"})
      |> Engram.Repo.update!(skip_tenant_check: true)

      # Provider reports a different email, but external_id is the same
      assert {:ok, found} =
               Accounts.find_or_create_by_external_id("clerk_stable", %{
                 email: "new@test.com"
               })

      assert found.id == user.id
      # external_id lookup takes precedence — email is NOT updated
      assert found.email == "old@test.com"
    end
  end

  describe "JWT" do
    test "generate and verify token round-trip" do
      user = insert(:user)

      token = Accounts.generate_jwt(user)
      assert {:ok, claims} = Accounts.verify_jwt(token)
      assert claims["user_id"] == user.id
    end

    test "rejects tampered token" do
      assert {:error, _reason} = Accounts.verify_jwt("garbage.token.here")
    end
  end
end
