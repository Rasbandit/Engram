defmodule Engram.Auth do
  @moduledoc "Auth provider dispatch. Reads :auth_provider config to select the active provider."

  def provider do
    case Application.get_env(:engram, :auth_provider, :local) do
      :local -> Engram.Auth.Providers.Local
      :clerk -> Engram.Auth.Providers.Clerk
      other -> raise "Invalid :auth_provider config: #{inspect(other)}. Must be :local or :clerk"
    end
  end

  def supports_credentials?, do: provider().supports_credentials?()
end
