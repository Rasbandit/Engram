defmodule Engram.Repo.Migrations.AddNoteEncryptionColumns do
  use Ecto.Migration

  def change do
    alter table(:notes) do
      add :content_ciphertext, :binary
      add :content_nonce, :binary
      add :title_ciphertext, :binary
      add :title_nonce, :binary
      add :tags_ciphertext, :binary
      add :tags_nonce, :binary
    end
  end
end
