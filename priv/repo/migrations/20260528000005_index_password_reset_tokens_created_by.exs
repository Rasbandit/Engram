defmodule Engram.Repo.Migrations.IndexPasswordResetTokensCreatedBy do
  use Ecto.Migration

  # Splinter flagged the FK `password_reset_tokens.created_by` as unindexed.
  # Matches the pattern set by the invites migration (index on created_by).
  def change do
    create index(:password_reset_tokens, [:created_by])
  end
end
