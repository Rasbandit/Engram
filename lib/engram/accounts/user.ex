defmodule Engram.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :password_hash, :string
    field :clerk_id, :string
    field :display_name, :string

    # Virtual field — never persisted, used for registration/login
    field :password, :string, virtual: true, redact: true

    belongs_to :plan, Engram.Billing.Plan
    has_many :notes, Engram.Notes.Note
    has_many :api_keys, Engram.Accounts.ApiKey
    # has_many :vaults, Engram.Vaults.Vault  # added in Task 3 once Vault schema exists

    timestamps(type: :utc_datetime, inserted_at: :created_at)
  end

  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :password, :display_name])
    |> validate_required([:email, :password])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must be a valid email")
    |> validate_length(:password, min: 8, max: 72)
    |> unique_constraint(:email)
    |> hash_password()
  end

  defp hash_password(changeset) do
    case get_change(changeset, :password) do
      nil -> changeset
      password -> put_change(changeset, :password_hash, Argon2.hash_pwd_salt(password))
    end
  end
end
