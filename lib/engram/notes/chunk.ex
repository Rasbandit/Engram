defmodule Engram.Notes.Chunk do
  use Ecto.Schema
  import Ecto.Changeset

  schema "chunks" do
    field :position, :integer
    field :heading_path, :string
    field :char_start, :integer
    field :char_end, :integer
    field :qdrant_point_id, Ecto.UUID

    belongs_to :note, Engram.Notes.Note
    belongs_to :user, Engram.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(chunk, attrs) do
    chunk
    |> cast(attrs, [
      :position,
      :heading_path,
      :char_start,
      :char_end,
      :qdrant_point_id,
      :note_id,
      :user_id
    ])
    |> validate_required([
      :position,
      :char_start,
      :char_end,
      :qdrant_point_id,
      :note_id,
      :user_id
    ])
    |> unique_constraint([:note_id, :position])
  end
end
