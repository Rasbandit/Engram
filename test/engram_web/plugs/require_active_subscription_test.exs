defmodule EngramWeb.Plugs.RequireActiveSubscriptionTest do
  use EngramWeb.ConnCase, async: true

  alias EngramWeb.Plugs.RequireActiveSubscription

  describe "call/2" do
    test "passes through for user in trial period", %{conn: conn} do
      user = insert(:user)
      conn = assign(conn, :current_user, user) |> RequireActiveSubscription.call([])
      refute conn.halted
    end

    test "passes through for user with active subscription", %{conn: conn} do
      user = insert(:user, inserted_at: DateTime.add(DateTime.utc_now(), -30, :day))
      insert(:subscription, user: user, status: "active")
      conn = assign(conn, :current_user, user) |> RequireActiveSubscription.call([])
      refute conn.halted
    end

    test "halts with 403 for expired trial with no subscription", %{conn: conn} do
      user = insert(:user, inserted_at: DateTime.add(DateTime.utc_now(), -30, :day))
      conn = assign(conn, :current_user, user) |> RequireActiveSubscription.call([])
      assert conn.halted
      assert conn.status == 403
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "subscription_required"
    end

    test "halts with 403 for canceled subscription past trial", %{conn: conn} do
      user = insert(:user, inserted_at: DateTime.add(DateTime.utc_now(), -30, :day))
      insert(:subscription, user: user, status: "canceled")
      conn = assign(conn, :current_user, user) |> RequireActiveSubscription.call([])
      assert conn.halted
      assert conn.status == 403
    end
  end
end
