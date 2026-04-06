defmodule Engram.Notes.Note do
  use Ecto.Schema
  import Ecto.Changeset

  schema "notes" do
    field :path, :string
    field :title, :string
    field :content, :string
    field :folder, :string
    field :tags, {:array, :string}, default: []
    field :version, :integer, default: 1
    field :content_hash, :string
    field :embed_hash, :string
    field :mtime, :float
    field :deleted_at, :utc_datetime_usec

    belongs_to :user, Engram.Accounts.User
    has_many :chunks, Engram.Notes.Chunk

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  def changeset(note, attrs) do
    note
    |> cast(attrs, [
      :path,
      :title,
      :content,
      :folder,
      :tags,
      :version,
      :content_hash,
      :mtime,
      :user_id,
      :deleted_at
    ])
    |> validate_required([:path, :user_id])
    |> unique_constraint([:user_id, :path])
  end
end
