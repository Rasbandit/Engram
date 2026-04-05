defmodule EngramWeb.Plugs.RequireActiveSubscription do
  @moduledoc """
  Plug that checks whether the current user has an active subscription or is within trial.
  Returns 403 with `subscription_required` error if not.

  Must run AFTER EngramWeb.Plugs.Auth (needs conn.assigns.current_user).
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    user = conn.assigns.current_user

    if Engram.Billing.active?(user) do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(403, Jason.encode!(%{error: "subscription_required"}))
      |> halt()
    end
  end
end
