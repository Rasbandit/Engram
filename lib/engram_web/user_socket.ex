defmodule EngramWeb.UserSocket do
  use Phoenix.Socket

  channel "sync:*", EngramWeb.SyncChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case authenticate(token) do
      {:ok, user} ->
        {:ok, assign(socket, :current_user, user)}

      {:error, _reason} ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.current_user.id}"

  defp authenticate("engram_" <> _ = api_key) do
    Engram.Accounts.validate_api_key(api_key)
  end

  defp authenticate(jwt) do
    with {:ok, claims} <- Engram.Accounts.verify_jwt(jwt),
         user_id when is_integer(user_id) <- claims["user_id"] do
      {:ok, Engram.Accounts.get_user!(user_id)}
    else
      _ -> {:error, :invalid_token}
    end
  end
end
