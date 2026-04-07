defmodule Engram.Billing.UserOverride do
  use Ecto.Schema
  import Ecto.Changeset

  schema "user_overrides" do
    field :overrides, :map, default: %{}
    field :reason, :string

    belongs_to :user, Engram.Accounts.User

    timestamps(type: :utc_datetime, inserted_at: :created_at)
  end

  def changeset(override, attrs) do
    override
    |> cast(attrs, [:user_id, :overrides, :reason])
    |> validate_required([:user_id])
    |> unique_constraint(:user_id)
  end
end
