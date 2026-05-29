defmodule Engram.Repo.Migrations.AddFamilyIdToDeviceRefreshTokens do
  use Ecto.Migration

  def up do
    alter table(:device_refresh_tokens) do
      add :family_id, :uuid
    end

    # Each existing token becomes its own family, so legacy tokens keep working
    # (reuse detection only nukes siblings, and they have none).
    execute "UPDATE device_refresh_tokens SET family_id = gen_random_uuid() WHERE family_id IS NULL"

    alter table(:device_refresh_tokens) do
      modify :family_id, :uuid, null: false
    end

    create index(:device_refresh_tokens, [:family_id])
  end

  def down do
    drop index(:device_refresh_tokens, [:family_id])

    alter table(:device_refresh_tokens) do
      remove :family_id
    end
  end
end
