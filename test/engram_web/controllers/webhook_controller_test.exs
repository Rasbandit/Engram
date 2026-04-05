defmodule EngramWeb.WebhookControllerTest do
  use EngramWeb.ConnCase, async: true

  describe "POST /webhooks/stripe" do
    test "returns 400 when signature is missing", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/stripe", "{}")

      assert json_response(conn, 400)["error"] == "missing stripe-signature header"
    end

    test "returns 400 when signature is invalid", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("stripe-signature", "t=123,v1=bad")
        |> post("/webhooks/stripe", ~s({"type":"test"}))

      assert json_response(conn, 400)["error"] =~ "signature"
    end

    test "returns 200 and processes valid checkout.session.completed event", %{conn: conn} do
      user = insert(:user)

      payload =
        Jason.encode!(%{
          "type" => "checkout.session.completed",
          "data" => %{
            "object" => %{
              "customer" => "cus_webhook1",
              "subscription" => "sub_webhook1",
              "client_reference_id" => to_string(user.id),
              "metadata" => %{"tier" => "starter"}
            }
          }
        })

      timestamp = System.system_time(:second)
      secret = Application.get_env(:engram, :stripe_webhook_secret)
      signed_payload = "#{timestamp}.#{payload}"

      signature =
        :crypto.mac(:hmac, :sha256, secret, signed_payload) |> Base.encode16(case: :lower)

      sig_header = "t=#{timestamp},v1=#{signature}"

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("stripe-signature", sig_header)
        |> post("/webhooks/stripe", payload)

      assert json_response(conn, 200)["status"] == "ok"

      sub = Engram.Billing.get_subscription(user)
      assert sub.stripe_customer_id == "cus_webhook1"
      assert sub.tier == "starter"
    end

    test "returns 200 for unhandled event types", %{conn: conn} do
      payload = Jason.encode!(%{"type" => "invoice.paid", "data" => %{"object" => %{}}})

      timestamp = System.system_time(:second)
      secret = Application.get_env(:engram, :stripe_webhook_secret)
      signed_payload = "#{timestamp}.#{payload}"

      signature =
        :crypto.mac(:hmac, :sha256, secret, signed_payload) |> Base.encode16(case: :lower)

      sig_header = "t=#{timestamp},v1=#{signature}"

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("stripe-signature", sig_header)
        |> post("/webhooks/stripe", payload)

      assert json_response(conn, 200)["status"] == "ok"
    end
  end
end
