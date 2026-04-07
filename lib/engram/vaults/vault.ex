defmodule Engram.Vaults.Vault do
  use Ecto.Schema
  import Ecto.Changeset

  schema "vaults" do
    field :name, :string
    field :description, :string
    field :slug, :string
    field :client_id, :string
    field :is_default, :boolean, default: false
    field :deleted_at, :utc_datetime

    belongs_to :user, Engram.Accounts.User
    # has_many :notes and :attachments added in Task 6 once vault_id FK is added to those tables

    timestamps(type: :utc_datetime, inserted_at: :created_at)
  end

  def changeset(vault, attrs) do
    vault
    |> cast(attrs, [:name, :description, :slug, :client_id, :is_default, :user_id, :deleted_at])
    |> validate_required([:name, :slug, :user_id])
    |> unique_constraint([:user_id, :slug], name: :vaults_user_id_slug_index)
    |> unique_constraint([:user_id, :client_id], name: :vaults_user_id_client_id_index)
  end
end
