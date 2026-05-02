defmodule Engram.Repo.Migrations.PhaseBAddHmacColumns do
  use Ecto.Migration

  # Phase B.1 — adds HMAC fingerprint + envelope-encrypted display columns
  # for path, folder, tags, attachment path, and vault name. All nullable
  # at this stage; backfill populates legacy rows. Phase B.3 tightens to
  # NOT NULL after backfill is verified at 100%.

  def change do
    alter table(:notes) do
      add :path_ciphertext, :binary
      add :path_nonce, :binary
      add :path_hmac, :binary
      add :folder_ciphertext, :binary
      add :folder_nonce, :binary
      add :folder_hmac, :binary
      add :tags_hmac, {:array, :binary}, default: []
      # tags_ciphertext + tags_nonce already exist from Phase 4.
    end

    alter table(:attachments) do
      add :path_ciphertext, :binary
      add :path_nonce, :binary
      add :path_hmac, :binary
    end

    alter table(:vaults) do
      add :name_ciphertext, :binary
      add :name_nonce, :binary
      add :name_hmac, :binary
    end

    create index(:notes, [:user_id, :vault_id, :path_hmac])
    create index(:notes, [:user_id, :vault_id, :folder_hmac])
    create index(:notes, [:tags_hmac], using: "GIN")
    create index(:attachments, [:user_id, :vault_id, :path_hmac])
    create index(:vaults, [:user_id, :name_hmac])
  end
end
