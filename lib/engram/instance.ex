defmodule Engram.Instance do
  @moduledoc """
  Instance-global settings (self-host). Singleton row at id=1.
  registration_mode controls self-registration: closed | invite_only | open.
  """
  alias Engram.Instance.InstanceSettings
  alias Engram.Repo

  @default_mode "invite_only"

  @doc """
  Returns the current registration mode. Falls back to the application-configured
  default (`:default_registration_mode`, settable via the `ENGRAM_DEFAULT_REGISTRATION_MODE`
  env var) when no instance_settings row exists yet. The app-env default lets CI
  pin "open" without rewriting every e2e fixture; production keeps "invite_only".
  """
  def registration_mode do
    case Repo.get(InstanceSettings, 1) do
      nil -> Application.get_env(:engram, :default_registration_mode, @default_mode)
      %InstanceSettings{registration_mode: mode} -> mode
    end
  end

  @doc "Sets the registration mode. Upserts the singleton row at id=1."
  def set_registration_mode(mode) when is_binary(mode) do
    if mode in InstanceSettings.modes() do
      %InstanceSettings{id: 1}
      |> InstanceSettings.changeset(%{registration_mode: mode})
      |> Repo.insert(
        on_conflict: [
          set: [
            registration_mode: mode,
            updated_at: DateTime.utc_now(:second)
          ]
        ],
        conflict_target: :id
      )
    else
      {:error, :invalid_mode}
    end
  end
end
