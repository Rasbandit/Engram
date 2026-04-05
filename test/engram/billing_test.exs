defmodule Engram.BillingTest do
  use Engram.DataCase, async: true

  alias Engram.Billing
  alias Engram.Billing.Subscription

  describe "tier/1" do
    test "returns :none for user with no subscription" do
      user = insert(:user)
      assert Billing.tier(user) == :none
    end

    test "returns tier atom for user with active subscription" do
      user = insert(:user)
      insert(:subscription, user: user, tier: "starter", status: "active")
      assert Billing.tier(user) == :starter
    end

    test "returns tier atom for user with trialing subscription" do
      user = insert(:user)
      insert(:subscription, user: user, tier: "starter", status: "trialing")
      assert Billing.tier(user) == :starter
    end

    test "returns :none for user with canceled subscription" do
      user = insert(:user)
      insert(:subscription, user: user, tier: "starter", status: "canceled")
      assert Billing.tier(user) == :none
    end
  end

  describe "active?/1" do
    test "returns false for user with no subscription" do
      user = insert(:user)
      assert Billing.active?(user) == false
    end

    test "returns true for user with trialing subscription" do
      user = insert(:user)
      insert(:subscription, user: user, status: "trialing")
      assert Billing.active?(user) == true
    end

    test "returns true for user with active subscription" do
      user = insert(:user)
      insert(:subscription, user: user, status: "active")
      assert Billing.active?(user) == true
    end

    test "returns true for user with past_due subscription" do
      user = insert(:user)
      insert(:subscription, user: user, status: "past_due")
      assert Billing.active?(user) == true
    end

    test "returns false for user with canceled subscription" do
      user = insert(:user)
      insert(:subscription, user: user, status: "canceled")
      assert Billing.active?(user) == false
    end
  end

  describe "get_subscription/1" do
    test "returns nil for user with no subscription" do
      user = insert(:user)
      assert Billing.get_subscription(user) == nil
    end

    test "returns subscription for user" do
      user = insert(:user)
      sub = insert(:subscription, user: user)
      result = Billing.get_subscription(user)
      assert result.id == sub.id
    end
  end

  describe "trial_days_remaining/1" do
    test "returns days remaining for trialing subscription" do
      user = insert(:user)
      period_end = DateTime.add(DateTime.utc_now(), 5, :day)
      insert(:subscription, user: user, status: "trialing", current_period_end: period_end)
      days = Billing.trial_days_remaining(user)
      assert days >= 4 and days <= 5
    end

    test "returns 0 for user with no subscription" do
      user = insert(:user)
      assert Billing.trial_days_remaining(user) == 0
    end

    test "returns 0 for user with active (non-trial) subscription" do
      user = insert(:user)
      insert(:subscription, user: user, status: "active")
      assert Billing.trial_days_remaining(user) == 0
    end
  end

  describe "upsert_from_stripe_event/1" do
    test "creates subscription from checkout.session.completed" do
      user = insert(:user)

      event = %{
        "type" => "checkout.session.completed",
        "data" => %{
          "object" => %{
            "customer" => "cus_test123",
            "subscription" => "sub_test123",
            "client_reference_id" => to_string(user.id),
            "metadata" => %{"tier" => "starter"}
          }
        }
      }

      assert {:ok, %Subscription{} = sub} = Billing.upsert_from_stripe_event(event)
      assert sub.user_id == user.id
      assert sub.stripe_customer_id == "cus_test123"
      assert sub.stripe_subscription_id == "sub_test123"
      assert sub.tier == "starter"
      assert sub.status == "trialing"
    end

    test "updates subscription from customer.subscription.updated" do
      user = insert(:user)

      insert(:subscription,
        user: user,
        stripe_subscription_id: "sub_test123",
        stripe_customer_id: "cus_test123",
        tier: "starter",
        status: "active"
      )

      event = %{
        "type" => "customer.subscription.updated",
        "data" => %{
          "object" => %{
            "id" => "sub_test123",
            "customer" => "cus_test123",
            "status" => "past_due",
            "current_period_end" => 1_750_000_000,
            "items" => %{
              "data" => [%{"price" => %{"id" => "price_pro_test"}}]
            }
          }
        }
      }

      assert {:ok, %Subscription{} = sub} = Billing.upsert_from_stripe_event(event)
      assert sub.status == "past_due"
      assert sub.tier == "pro"
    end

    test "marks subscription canceled from customer.subscription.deleted" do
      user = insert(:user)

      insert(:subscription,
        user: user,
        stripe_subscription_id: "sub_test123",
        stripe_customer_id: "cus_test123",
        status: "active"
      )

      event = %{
        "type" => "customer.subscription.deleted",
        "data" => %{
          "object" => %{
            "id" => "sub_test123",
            "customer" => "cus_test123",
            "status" => "canceled",
            "current_period_end" => 1_750_000_000,
            "items" => %{
              "data" => [%{"price" => %{"id" => "price_starter_test"}}]
            }
          }
        }
      }

      assert {:ok, %Subscription{} = sub} = Billing.upsert_from_stripe_event(event)
      assert sub.status == "canceled"
    end
  end
end
