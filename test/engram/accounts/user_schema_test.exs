defmodule Engram.Accounts.UserSchemaTest do
  # T3.0.5 — User schema must redact key material from inspect/1 and
  # Jason.Encoder must allowlist serializable fields. Closes the
  # `inspect(user)` regression class and the `json(conn, %{user: user})`
  # landmine identified in the encryption tier-3 audit.
  use Engram.DataCase, async: true

  alias Engram.Accounts.User

  defp user_with_secrets do
    %User{
      id: 1,
      email: "alice@example.com",
      role: "member",
      display_name: "Alice",
      external_id: "ext-1",
      password_hash: "$2b$12$secrethashvalue",
      encrypted_dek: <<0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE>>,
      dek_version: 7,
      key_provider: "local"
    }
  end

  describe "inspect/1" do
    test "masks encrypted_dek bytes" do
      out = inspect(user_with_secrets())
      refute out =~ "deadbeef"
      refute out =~ "DEADBEEF"
      refute out =~ ~r/<<0xDE/i
      refute out =~ "encrypted_dek:"
    end

    test "drops the field entirely from inspect output (Ecto redact behavior)" do
      out = inspect(user_with_secrets())
      # Ecto redact: true causes inspect/1 to omit the field and emit `...` truncation marker.
      assert out =~ "..."
    end

    test "masks password_hash" do
      out = inspect(user_with_secrets())
      refute out =~ "secrethashvalue"
    end

    test "masks dek_version and key_provider (defense-in-depth)" do
      out = inspect(user_with_secrets())
      refute out =~ "dek_version: 7"
      refute out =~ ~s|key_provider: "local"|
    end
  end

  describe "Jason.Encoder" do
    test "encodes only allowlisted fields" do
      json = Jason.encode!(user_with_secrets())
      decoded = Jason.decode!(json)

      allowed = ~w(id email role display_name created_at updated_at)
      assert MapSet.new(Map.keys(decoded)) == MapSet.new(allowed)
    end

    test "never emits encrypted_dek, password_hash, dek_version, key_provider" do
      json = Jason.encode!(user_with_secrets())
      refute json =~ "encrypted_dek"
      refute json =~ "password_hash"
      refute json =~ "dek_version"
      refute json =~ "key_provider"
      refute json =~ "deadbeef"
      refute json =~ "secrethashvalue"
    end
  end
end
