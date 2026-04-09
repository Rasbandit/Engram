defmodule Engram.Fixtures do
  @moduledoc "Convenience helpers for inserting common test fixtures."

  alias Engram.Repo

  @doc """
  Inserts an active subscription for a user.

  Accepts optional attribute overrides (status, tier, etc.).
  """
  def subscription_fixture(user, attrs \\ %{}) do
    defaults = %{
      user_id: user.id,
      status: "active",
      tier: "starter",
      stripe_customer_id: "cus_#{System.unique_integer([:positive])}",
      stripe_subscription_id: "sub_#{System.unique_integer([:positive])}"
    }

    Repo.insert!(
      struct(Engram.Billing.Subscription, Map.merge(defaults, attrs)),
      skip_tenant_check: true
    )
  end
end
