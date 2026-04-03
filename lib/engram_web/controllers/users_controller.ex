defmodule EngramWeb.UsersController do
  use EngramWeb, :controller

  def me(conn, _params) do
    user = conn.assigns.current_user
    json(conn, %{user: %{id: user.id, email: user.email}})
  end
end
