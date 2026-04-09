defmodule Engram.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :clerk_id, :string
    field :display_name, :string

    belongs_to :plan, Engram.Billing.Plan
    has_many :notes, Engram.Notes.Note
    has_many :api_keys, Engram.Accounts.ApiKey
    has_many :vaults, Engram.Vaults.Vault

    timestamps(type: :utc_datetime, inserted_at: :created_at)
  end
end
