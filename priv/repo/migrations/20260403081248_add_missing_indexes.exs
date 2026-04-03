defmodule Engram.Repo.Migrations.AddMissingIndexes do
  use Ecto.Migration

  def change do
    # GIN index for tag filtering in Postgres
    create index(:notes, [:tags], name: :idx_notes_tags, using: "GIN")

    # RLS policies filter on user_id — standalone indexes for chunks and attachments
    create index(:chunks, [:user_id], name: :idx_chunks_user)
    create index(:attachments, [:user_id], name: :idx_attachments_user)

    # Upgrade api_keys hash index to unique
    drop index(:api_keys, [:key_hash], name: :idx_api_keys_hash)
    create unique_index(:api_keys, [:key_hash], name: :idx_api_keys_hash)
  end
end
