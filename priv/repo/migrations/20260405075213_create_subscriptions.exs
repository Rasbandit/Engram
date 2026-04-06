defmodule Engram.Repo.Migrations.CreateSubscriptions do
  use Ecto.Migration

  def change do
    create table(:subscriptions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :stripe_customer_id, :string, null: false
      add :stripe_subscription_id, :string
      add :tier, :string, null: false, default: "trial"
      add :status, :string, null: false, default: "trialing"
      add :current_period_end, :utc_datetime

      timestamps(type: :utc_datetime, inserted_at: :created_at)
    end

    create unique_index(:subscriptions, [:user_id])
    create index(:subscriptions, [:stripe_customer_id])
    create index(:subscriptions, [:stripe_subscription_id])
  end
end
