defmodule Engram.Billing.Workers.OverrideExpirySweepTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Billing.UserLimitOverride
  alias Engram.Billing.Workers.OverrideExpirySweep
  alias Engram.Repo

  defp insert_override(user, expires_at) do
    Repo.insert!(%UserLimitOverride{
      user_id: user.id,
      key: "notes_cap",
      value: %{"v" => 100},
      reason: "test",
      set_by: "test",
      expires_at: expires_at
    })
  end

  describe "perform/1" do
    test "deletes rows where expires_at <= now()" do
      user1 = insert(:user)
      user2 = insert(:user)

      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

      expired = insert_override(user1, past)
      not_expired = insert_override(user2, future)

      assert :ok = perform_job(OverrideExpirySweep, %{})

      refute Repo.get(UserLimitOverride, expired.id)
      assert Repo.get(UserLimitOverride, not_expired.id)
    end

    test "ignores rows with expires_at IS NULL" do
      user = insert(:user)

      permanent =
        Repo.insert!(%UserLimitOverride{
          user_id: user.id,
          key: "notes_cap",
          value: %{"v" => 100},
          reason: "test",
          set_by: "test"
        })

      assert :ok = perform_job(OverrideExpirySweep, %{})

      assert Repo.get(UserLimitOverride, permanent.id)
    end

    test "emits telemetry event with count" do
      user = insert(:user)
      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
      insert_override(user, past)

      :telemetry_test.attach_event_handlers(self(), [
        [:engram, :billing, :overrides, :expired]
      ])

      assert :ok = perform_job(OverrideExpirySweep, %{})

      assert_received {[:engram, :billing, :overrides, :expired], _ref, %{count: 1}, %{}}
    end
  end
end
