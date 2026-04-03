defmodule Engram.Repo.Migrations.AddAttachmentContent do
  use Ecto.Migration

  def change do
    alter table(:attachments) do
      add :content, :binary
      add :content_hash, :text
    end
  end
end
