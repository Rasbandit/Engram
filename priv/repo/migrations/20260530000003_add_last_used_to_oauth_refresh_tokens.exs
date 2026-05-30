defmodule Engram.Repo.Migrations.AddLastUsedToOauthRefreshTokens do
  use Ecto.Migration

  def change do
    alter table(:oauth_refresh_tokens) do
      add :last_used_at, :utc_datetime_usec
      add :last_used_ip, :inet
    end

    create index(:oauth_refresh_tokens, [:user_id, :client_id],
             where: "revoked_at IS NULL AND consumed_at IS NULL",
             name: :idx_oauth_refresh_tokens_user_client_active)
  end
end
