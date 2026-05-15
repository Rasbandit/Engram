defmodule Engram.OnboardingTest do
  use Engram.DataCase, async: true

  alias Engram.Onboarding
  alias Engram.Onboarding.Agreement

  describe "accept_terms/3" do
    test "inserts an agreement row for the user and version" do
      user = insert(:user)

      {:ok, %Agreement{} = agreement} =
        Onboarding.accept_terms(user, "2026-05-15", %{
          ip_address: "192.168.1.1",
          user_agent: "Mozilla/5.0"
        })

      assert agreement.user_id == user.id
      assert agreement.document == "terms_of_service"
      assert agreement.version == "2026-05-15"
      assert agreement.ip_address == "192.168.1.1"
      assert agreement.user_agent == "Mozilla/5.0"
      assert agreement.accepted_at != nil
    end

    test "allows the same user to accept multiple versions" do
      user = insert(:user)
      {:ok, _} = Onboarding.accept_terms(user, "2026-01-01", %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})

      rows =
        Engram.Repo.with_tenant(user.id, fn ->
          Engram.Repo.all(Agreement)
        end)
        |> elem(1)

      assert length(rows) == 2
    end

    test "rejects empty version" do
      user = insert(:user)
      assert {:error, %Ecto.Changeset{}} = Onboarding.accept_terms(user, "", %{})
    end
  end
end
