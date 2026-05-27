defmodule Engram.Repo.Migrations.CreateTermsVersions do
  use Ecto.Migration

  @moduledoc """
  Canonical legal-document versions. Single source for the content hash the
  accept endpoint verifies against, plus the effective_date that drives the
  non-blocking notice window vs hard cutoff. Append-only/immutable in practice:
  a correction is a new version, never an edit. Global (non-tenant), like
  email_suppressions.
  """

  def change do
    create table(:terms_versions) do
      add :document, :string, null: false
      add :version, :string, null: false
      add :content_hash, :string, null: false
      add :material, :boolean, null: false, default: true
      add :effective_date, :date
      add :changelog, :text

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:terms_versions, [:document, :version])

    create constraint(:terms_versions, :document_must_be_valid,
             check: "document IN ('terms_of_service', 'privacy_policy')"
           )
  end
end
