defmodule Engram.Billing.Subscription do
  use Ecto.Schema
  import Ecto.Changeset

  schema "subscriptions" do
    field :stripe_customer_id, :string
    field :stripe_subscription_id, :string
    field :tier, :string, default: "trial"
    field :status, :string, default: "trialing"
    field :current_period_end, :utc_datetime

    belongs_to :user, Engram.Accounts.User

    timestamps(type: :utc_datetime, inserted_at: :created_at)
  end

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [
      :user_id,
      :stripe_customer_id,
      :stripe_subscription_id,
      :tier,
      :status,
      :current_period_end
    ])
    |> validate_required([:user_id, :stripe_customer_id, :tier, :status])
    |> validate_inclusion(:tier, ~w(trial starter pro))
    |> validate_inclusion(:status, ~w(trialing active past_due canceled))
    |> unique_constraint(:user_id)
  end
end
