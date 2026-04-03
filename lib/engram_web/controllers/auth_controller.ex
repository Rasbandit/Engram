defmodule EngramWeb.AuthController do
  use EngramWeb, :controller

  alias Engram.Accounts

  def register(conn, params) do
    case Accounts.register_user(params) do
      {:ok, user} ->
        token = Accounts.generate_jwt(user)
        json(conn, %{user: %{id: user.id, email: user.email}, token: token})

      {:error, changeset} ->
        conn
        |> put_status(422)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def login(conn, %{"email" => email, "password" => password})
      when is_binary(email) and is_binary(password) do
    case Accounts.authenticate_user(email, password) do
      {:ok, user} ->
        token = Accounts.generate_jwt(user)
        json(conn, %{user: %{id: user.id, email: user.email}, token: token})

      {:error, :invalid_credentials} ->
        conn
        |> put_status(401)
        |> json(%{error: "invalid credentials"})
    end
  end

  def login(conn, _params) do
    conn
    |> put_status(422)
    |> json(%{error: "email and password are required"})
  end

  def create_api_key(conn, %{"name" => name}) do
    user = conn.assigns.current_user

    case Accounts.create_api_key(user, name) do
      {:ok, raw_key, api_key} ->
        json(conn, %{key: raw_key, name: api_key.name, id: api_key.id})

      {:error, changeset} ->
        conn
        |> put_status(422)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def revoke_api_key(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case Integer.parse(id) do
      {int_id, ""} ->
        case Accounts.revoke_api_key(user, int_id) do
          :ok ->
            json(conn, %{deleted: true})

          {:error, _} ->
            conn |> put_status(404) |> json(%{error: "API key not found"})
        end

      _ ->
        conn |> put_status(400) |> json(%{error: "invalid API key id"})
    end
  end

  defp format_errors(changeset), do: EngramWeb.format_errors(changeset)
end
