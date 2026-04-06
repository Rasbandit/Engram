defmodule Engram.Repo.Migrations.CreateCoreTables do
  use Ecto.Migration

  def change do
    # ── Users ──────────────────────────────────────────────────────
    create table(:users) do
      add :email, :text, null: false
      add :password_hash, :text, null: false
      add :display_name, :text
      timestamps(type: :utc_datetime, inserted_at: :created_at)
    end

    create unique_index(:users, [:email])

    # ── Notes ──────────────────────────────────────────────────────
    create table(:notes) do
      add :user_id, references(:users, on_delete: :nothing), null: false
      add :path, :text, null: false
      add :title, :text
      add :content, :text
      add :folder, :text
      add :tags, {:array, :text}, default: []
      add :version, :integer, null: false, default: 1
      add :content_hash, :text
      add :mtime, :float
      add :deleted_at, :utc_datetime
      timestamps(type: :utc_datetime, inserted_at: :created_at)
    end

    create unique_index(:notes, [:user_id, :path])
    create index(:notes, [:user_id, :updated_at], name: :idx_notes_user_updated)
    create index(:notes, [:user_id, :folder], name: :idx_notes_user_folder)

    create index(:notes, [:user_id, :deleted_at],
             name: :idx_notes_user_deleted,
             where: "deleted_at IS NOT NULL"
           )

    # ── Chunks ─────────────────────────────────────────────────────
    create table(:chunks) do
      add :note_id, references(:notes, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :nothing), null: false
      add :position, :smallint, null: false
      add :heading_path, :text
      add :char_start, :integer, null: false
      add :char_end, :integer, null: false
      add :qdrant_point_id, :uuid, null: false
      timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
    end

    create unique_index(:chunks, [:note_id, :position])
    create index(:chunks, [:note_id], name: :idx_chunks_note)

    # ── Attachments ────────────────────────────────────────────────
    create table(:attachments) do
      add :user_id, references(:users, on_delete: :nothing), null: false
      add :path, :text, null: false
      add :mime_type, :text
      add :size_bytes, :bigint
      add :mtime, :float
      add :deleted_at, :utc_datetime
      timestamps(type: :utc_datetime, inserted_at: :created_at)
    end

    create unique_index(:attachments, [:user_id, :path])

    # ── API Keys ───────────────────────────────────────────────────
    create table(:api_keys) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :key_hash, :text, null: false
      add :name, :text
      add :last_used, :utc_datetime
      timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
    end

    create index(:api_keys, [:key_hash], name: :idx_api_keys_hash)
  end
end
