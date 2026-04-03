defmodule Engram.Attachments.Attachment do
  use Ecto.Schema
  import Ecto.Changeset

  schema "attachments" do
    field :path, :string
    field :mime_type, :string
    field :size_bytes, :integer
    field :mtime, :float
    field :deleted_at, :utc_datetime

    belongs_to :user, Engram.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [:path, :mime_type, :size_bytes, :mtime, :user_id])
    |> validate_required([:path, :user_id])
    |> unique_constraint([:user_id, :path])
  end
end
