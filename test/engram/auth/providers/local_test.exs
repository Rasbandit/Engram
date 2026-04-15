defmodule Engram.Auth.Providers.LocalTest do
  use Engram.DataCase, async: true

  import Ecto.Query
  alias Engram.Auth.Providers.Local

  describe "register_user/3" do
    test "creates a user with hashed password" do
      assert {:ok, %{external_id: ext_id, email: "new@local.test"}} =
               Local.register_user("new@local.test", "StrongPass123!", %{})

      assert is_binary(ext_id)
    end

    test "first user gets admin role" do
      {:ok, %{external_id: ext_id}} = Local.register_user("admin@local.test", "StrongPass123!", %{})
      user = Engram.Repo.one!(from u in Engram.Accounts.User, where: u.external_id == ^ext_id)
      assert user.role == "admin"
    end

    test "second user gets member role" do
      {:ok, _} = Local.register_user("first@local.test", "StrongPass123!", %{})
      {:ok, %{external_id: ext_id}} = Local.register_user("second@local.test", "StrongPass123!", %{})
      user = Engram.Repo.one!(from u in Engram.Accounts.User, where: u.external_id == ^ext_id)
      assert user.role == "member"
    end

    test "rejects duplicate email" do
      {:ok, _} = Local.register_user("dup@local.test", "StrongPass123!", %{})
      assert {:error, _} = Local.register_user("dup@local.test", "StrongPass123!", %{})
    end
  end

  describe "authenticate_credentials/2" do
    test "returns external_id and email for valid credentials" do
      {:ok, %{external_id: ext_id}} = Local.register_user("auth@local.test", "StrongPass123!", %{})

      assert {:ok, %{external_id: ^ext_id, email: "auth@local.test"}} =
               Local.authenticate_credentials("auth@local.test", "StrongPass123!")
    end

    test "rejects wrong password" do
      {:ok, _} = Local.register_user("wrong@local.test", "StrongPass123!", %{})

      assert {:error, :invalid_credentials} =
               Local.authenticate_credentials("wrong@local.test", "WrongPass!")
    end

    test "rejects nonexistent user (constant-time)" do
      assert {:error, :invalid_credentials} =
               Local.authenticate_credentials("noone@local.test", "Whatever123!")
    end
  end

  describe "verify_token/1" do
    test "verifies a self-issued JWT" do
      {:ok, %{external_id: ext_id}} = Local.register_user("jwt@local.test", "StrongPass123!", %{})
      token = Local.issue_access_token(ext_id, "jwt@local.test")

      assert {:ok, %{external_id: ^ext_id, email: "jwt@local.test"}} = Local.verify_token(token)
    end

    test "rejects expired token" do
      claims = %{
        "sub" => "fake_id",
        "email" => "exp@test.com",
        "exp" => :os.system_time(:second) - 60,
        "iss" => "engram",
        "aud" => "engram"
      }

      {:ok, token, _} = Engram.Token.generate_and_sign(claims)
      assert {:error, _} = Local.verify_token(token)
    end

    test "rejects garbage" do
      assert {:error, _} = Local.verify_token("not.a.jwt")
    end
  end

  describe "supports_credentials?/0" do
    test "returns true" do
      assert Local.supports_credentials?() == true
    end
  end
end
