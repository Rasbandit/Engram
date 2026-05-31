defmodule Mix.Tasks.Engram.BackfillOnboardingActionsTest do
  use Engram.DataCase, async: false

  alias Engram.Onboarding
  alias Engram.Vaults

  test "inserts first_vault_created for every user with at least one vault" do
    user_with = insert_user()
    user_without = insert_user()
    {:ok, _} = Vaults.create_vault(user_with, %{name: "Main"})

    # Simulate a legacy user: clear the row created by the T5 hook so the test
    # exercises pure backfill.
    Engram.Repo.delete_all(Engram.Onboarding.Action)

    Mix.Tasks.Engram.BackfillOnboardingActions.run([])

    assert ["first_vault_created"] = Onboarding.list_actions(user_with.id)
    assert [] = Onboarding.list_actions(user_without.id)
  end

  test "idempotent — second run is a no-op" do
    user = insert_user()
    {:ok, _} = Vaults.create_vault(user, %{name: "Main"})

    Mix.Tasks.Engram.BackfillOnboardingActions.run([])
    Mix.Tasks.Engram.BackfillOnboardingActions.run([])

    assert ["first_vault_created"] = Onboarding.list_actions(user.id)
  end
end
