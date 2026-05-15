defmodule Engram.Onboarding do
  @moduledoc """
  Onboarding context: TOS acceptance tracking and wizard-state computation.

  Wizard is fully disabled when `Application.get_env(:engram, :billing_enabled)`
  is false (self-host mode). In that mode `status/1` reports `next_step: :done`
  unconditionally and `RequireOnboarding` is a no-op.
  """

  alias Engram.Onboarding.Agreement
  alias Engram.Repo

  @terms_document "terms_of_service"

  @doc """
  Record that `user` accepted document version `version`. `meta` may carry
  `:ip_address` (string) and `:user_agent` (string) for audit purposes.
  Returns `{:ok, %Agreement{}}` or `{:error, %Ecto.Changeset{}}`.
  """
  def accept_terms(user, version, meta) when is_binary(version) do
    attrs = %{
      user_id: user.id,
      document: @terms_document,
      version: version,
      accepted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      ip_address: Map.get(meta, :ip_address),
      user_agent: Map.get(meta, :user_agent)
    }

    %Agreement{}
    |> Agreement.changeset(attrs)
    |> Repo.insert(skip_tenant_check: true)
  end
end
