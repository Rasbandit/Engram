defmodule EngramWeb.UsersController do
  use EngramWeb, :controller

  alias Engram.Accounts

  def me(conn, _params) do
    user = conn.assigns.current_user

    json(conn, %{
      user: %{
        id: user.id,
        email: user.email,
        role: user.role,
        display_name: user.display_name
      }
    })
  end

  def update(conn, params) do
    user = conn.assigns.current_user
    attrs = Map.take(params, ["display_name"])

    case Accounts.update_profile(user, attrs) do
      {:ok, updated} ->
        json(conn, %{
          user: %{
            id: updated.id,
            email: updated.email,
            role: updated.role,
            display_name: updated.display_name
          }
        })

      {:error, %Ecto.Changeset{} = cs} ->
        details =
          Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
            Enum.reduce(opts, msg, fn {k, v}, acc ->
              String.replace(acc, "%{#{k}}", to_string(v))
            end)
          end)

        conn
        |> put_status(422)
        |> json(%{error: "validation_failed", details: details})
    end
  end

  def delete(conn, %{"password" => password}) when is_binary(password) do
    user = conn.assigns.current_user

    case Accounts.delete_self(user, password) do
      :ok ->
        json(conn, %{ok: true})

      {:error, :invalid_password} ->
        conn |> put_status(403) |> json(%{error: "invalid_password"})

      {:error, :last_admin} ->
        conn |> put_status(409) |> json(%{error: "last_admin"})

      {:error, _other} ->
        conn |> put_status(422) |> json(%{error: "delete_failed"})
    end
  end

  def delete(conn, _params) do
    conn |> put_status(400) |> json(%{error: "password_required"})
  end
end
