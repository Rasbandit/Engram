defmodule Engram.Billing.UserLimitOverrideTest do
  use Engram.DataCase, async: true

  alias Engram.Billing.UserLimitOverride
  alias Engram.Repo

  describe "changeset/2" do
    test "valid with required fields + catalog key" do
      user = insert(:user)

      attrs = %{
        user_id: user.id,
        key: "notes_cap",
        value: %{"v" => 100_000},
        reason: "enterprise grant",
        set_by: "admin:todd"
      }

      changeset = UserLimitOverride.changeset(%UserLimitOverride{}, attrs)
      assert changeset.valid?
    end

    test "invalid with unknown key" do
      user = insert(:user)

      attrs = %{
        user_id: user.id,
        key: "not_a_real_key",
        value: %{"v" => 100},
        reason: "x",
        set_by: "admin:todd"
      }

      changeset = UserLimitOverride.changeset(%UserLimitOverride{}, attrs)
      refute changeset.valid?
      assert "not a known limit key" in errors_on(changeset).key
    end

    test "invalid without :reason" do
      user = insert(:user)
      attrs = %{user_id: user.id, key: "notes_cap", value: %{"v" => 1}, set_by: "admin:todd"}

      changeset = UserLimitOverride.changeset(%UserLimitOverride{}, attrs)
      refute changeset.valid?
      assert :reason in Keyword.keys(changeset.errors)
    end

    test "invalid without :set_by" do
      user = insert(:user)
      attrs = %{user_id: user.id, key: "notes_cap", value: %{"v" => 1}, reason: "x"}

      changeset = UserLimitOverride.changeset(%UserLimitOverride{}, attrs)
      refute changeset.valid?
      assert :set_by in Keyword.keys(changeset.errors)
    end

    test "duplicate (user_id, key) second insert fails unique constraint" do
      user = insert(:user)

      attrs = %{
        user_id: user.id,
        key: "notes_cap",
        value: %{"v" => 1},
        reason: "x",
        set_by: "admin:todd"
      }

      assert {:ok, _} =
               %UserLimitOverride{}
               |> UserLimitOverride.changeset(attrs)
               |> Repo.insert(skip_tenant_check: true)

      assert {:error, changeset} =
               %UserLimitOverride{}
               |> UserLimitOverride.changeset(attrs)
               |> Repo.insert(skip_tenant_check: true)

      assert "has already been taken" in errors_on(changeset).user_id
    end

    test "expires_at is optional" do
      user = insert(:user)

      attrs = %{
        user_id: user.id,
        key: "notes_cap",
        value: %{"v" => 100_000},
        reason: "permanent grant",
        set_by: "admin:todd"
      }

      changeset = UserLimitOverride.changeset(%UserLimitOverride{}, attrs)
      assert changeset.valid?
    end
  end
end
