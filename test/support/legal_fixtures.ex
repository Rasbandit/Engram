defmodule Engram.LegalFixtures do
  @moduledoc "Insert terms_versions rows in tests."
  alias Engram.Legal.TermsVersion
  alias Engram.Repo

  @doc """
  Insert a version row. Defaults: terms_of_service, material, effective now.
  Pass `effective_date:` a `~D[]` in the future for the notice-window case.
  """
  def insert_version(attrs \\ %{}) do
    defaults = %{
      document: "terms_of_service",
      version: "2026-05-19",
      content_hash: "hash-" <> (attrs[:version] || "2026-05-19"),
      material: true,
      effective_date: nil,
      changelog: "test"
    }

    %TermsVersion{}
    |> TermsVersion.changeset(Map.merge(defaults, Map.new(attrs)))
    |> Repo.insert!(skip_tenant_check: true)
  end
end
