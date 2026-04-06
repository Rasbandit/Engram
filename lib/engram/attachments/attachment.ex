defmodule Engram.Attachments.Attachment do
  use Ecto.Schema
  import Ecto.Changeset

  @max_attachment_bytes 5 * 1024 * 1024

  schema "attachments" do
    field :path, :string
    field :content, :binary
    field :content_hash, :string
    field :mime_type, :string
    field :size_bytes, :integer
    field :mtime, :float
    field :storage_key, :string
    field :deleted_at, :utc_datetime

    belongs_to :user, Engram.Accounts.User

    timestamps(type: :utc_datetime, inserted_at: :created_at)
  end

  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [
      :path,
      :content,
      :content_hash,
      :mime_type,
      :size_bytes,
      :mtime,
      :user_id,
      :storage_key,
      :deleted_at
    ])
    |> validate_required([:path, :user_id, :content_hash, :mime_type, :size_bytes])
    |> validate_number(:size_bytes, less_than_or_equal_to: @max_attachment_bytes)
    |> unique_constraint([:user_id, :path])
  end

  def max_attachment_bytes, do: @max_attachment_bytes
end
