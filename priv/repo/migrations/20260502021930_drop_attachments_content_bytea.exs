defmodule Engram.Repo.Migrations.DropAttachmentsContentBytea do
  use Ecto.Migration

  def change do
    alter table(:attachments) do
      remove :content, :binary
    end
  end
end
