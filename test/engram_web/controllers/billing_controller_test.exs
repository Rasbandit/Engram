defmodule EngramWeb.BillingControllerTest do
  use EngramWeb.ConnCase, async: true

  alias Engram.Accounts

  setup %{conn: conn} do
    user = insert(:user)
    {:ok, raw_key, _api_key} = Accounts.create_api_key(user, "test")
    conn = put_req_header(conn, "authorization", "Bearer #{raw_key}")
    {:ok, conn: conn, user: user}
  end

  describe "GET /api/billing/status" do
    test "returns inactive status for new user with no subscription", %{conn: conn} do
      conn = get(conn, "/api/billing/status")
      body = json_response(conn, 200)
      assert body["tier"] == "none"
      assert body["active"] == false
      assert body["trial_days_remaining"] == 0
      assert body["subscription"] == nil
    end

    test "returns subscription status for subscribed user", %{conn: conn, user: user} do
      insert(:subscription, user: user, tier: "starter", status: "active")
      conn = get(conn, "/api/billing/status")
      body = json_response(conn, 200)
      assert body["tier"] == "starter"
      assert body["active"] == true
      assert body["subscription"]["status"] == "active"
    end

    test "returns 401 without auth" do
      conn = build_conn() |> get("/api/billing/status")
      assert json_response(conn, 401)
    end
  end

  describe "POST /api/billing/checkout-session" do
    test "returns 400 for invalid tier", %{conn: conn} do
      conn = post(conn, "/api/billing/checkout-session", %{"tier" => "invalid"})
      assert json_response(conn, 400)["error"] =~ "tier"
    end
  end
end
