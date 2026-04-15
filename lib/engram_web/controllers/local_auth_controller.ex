defmodule EngramWeb.LocalAuthController do
  use EngramWeb, :controller

  import Ecto.Query

  alias Engram.Accounts
  alias Engram.Auth.Providers.Local

  @refresh_cookie_opts [
    http_only: true,
    secure: true,
    same_site: "Lax",
    path: "/api/auth",
    max_age: 30 * 24 * 3600
  ]

  def register(conn, %{"email" => email, "password" => password})
      when is_binary(email) and is_binary(password) do
    case Local.register_user(email, password, %{}) do
      {:ok, %{external_id: ext_id, email: user_email}} ->
        user = Engram.Repo.one!(from u in Accounts.User, where: u.external_id == ^ext_id)
        access_token = Local.issue_access_token(ext_id, user_email)
        {raw_refresh, _record} = Accounts.create_refresh_token(user)

        conn
        |> put_resp_cookie("refresh_token", raw_refresh, @refresh_cookie_opts)
        |> put_status(:created)
        |> json(%{access_token: access_token, user: %{email: user.email, role: user.role}})

      {:error, _} ->
        conn |> put_status(422) |> json(%{error: "registration_failed"})
    end
  end

  def register(conn, _params) do
    conn |> put_status(422) |> json(%{error: "email and password required"})
  end

  def login(conn, %{"email" => email, "password" => password}) do
    case Local.authenticate_credentials(email, password) do
      {:ok, %{external_id: ext_id, email: user_email}} ->
        user = Engram.Repo.one!(from u in Accounts.User, where: u.external_id == ^ext_id)
        access_token = Local.issue_access_token(ext_id, user_email)
        {raw_refresh, _record} = Accounts.create_refresh_token(user)

        conn
        |> put_resp_cookie("refresh_token", raw_refresh, @refresh_cookie_opts)
        |> json(%{access_token: access_token, user: %{email: user.email, role: user.role}})

      {:error, _} ->
        conn |> put_status(401) |> json(%{error: "invalid_credentials"})
    end
  end

  def refresh(conn, _params) do
    conn = fetch_cookies(conn)

    case conn.req_cookies["refresh_token"] do
      nil ->
        conn |> put_status(401) |> json(%{error: "no_refresh_token"})

      raw_token ->
        case Accounts.consume_refresh_token(raw_token) do
          {:ok, user, new_raw_token, _record} ->
            access_token = Local.issue_access_token(user.external_id, user.email)

            conn
            |> put_resp_cookie("refresh_token", new_raw_token, @refresh_cookie_opts)
            |> json(%{access_token: access_token})

          {:error, _reason} ->
            conn
            |> delete_resp_cookie("refresh_token", path: "/api/auth")
            |> put_status(401)
            |> json(%{error: "invalid_refresh_token"})
        end
    end
  end

  def logout(conn, _params) do
    conn = fetch_cookies(conn)

    case conn.req_cookies["refresh_token"] do
      nil -> :ok
      raw_token ->
        token_hash = :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)
        Accounts.revoke_token_family(token_hash)
    end

    conn
    |> delete_resp_cookie("refresh_token", path: "/api/auth")
    |> send_resp(204, "")
  end
end
