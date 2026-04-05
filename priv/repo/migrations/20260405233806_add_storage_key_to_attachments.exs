defmodule Engram.Repo.Migrations.AddStorageKeyToAttachments do
  use Ecto.Migration

  def change do
    alter table(:attachments) do
      add :storage_key, :string
    end

    execute(
      "UPDATE attachments SET storage_key = CONCAT(user_id, '/', path) WHERE storage_key IS NULL",
      "SELECT 1"
    )
  end
end
