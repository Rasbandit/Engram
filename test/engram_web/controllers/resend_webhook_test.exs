defmodule EngramWeb.ResendWebhookTest do
  use EngramWeb.ConnCase, async: false

  alias Engram.Email.Suppression

  describe "POST /webhooks/resend — signature verification" do
    test "returns 400 when the signature is invalid", %{conn: conn} do
      payload = ~s({"type":"email.bounced","data":{"to":["x@example.com"]}})

      conn =
        conn
        |> with_resend_headers("evt_1", System.system_time(:second), "v1,not-a-real-sig")
        |> post("/webhooks/resend", payload)

      assert json_response(conn, 400)["error"] =~ "signature"
      refute Suppression.suppressed?("x@example.com")
    end

    test "returns 400 for a stale timestamp", %{conn: conn} do
      payload = ~s({"type":"email.bounced","data":{"to":["stale@example.com"]}})
      stale_ts = System.system_time(:second) - 360
      sig = sign_resend("evt_stale", stale_ts, payload)

      conn =
        conn
        |> with_resend_headers("evt_stale", stale_ts, sig)
        |> post("/webhooks/resend", payload)

      assert json_response(conn, 400)["error"] =~ "old"
      refute Suppression.suppressed?("stale@example.com")
    end
  end

  describe "POST /webhooks/resend — event handling" do
    test "suppresses recipients on a bounce", %{conn: conn} do
      conn = post_resend(conn, "evt_b", "email.bounced", ["bounce@example.com"])

      assert json_response(conn, 200)["status"] == "ok"
      assert Suppression.suppressed?("bounce@example.com")
    end

    test "suppresses recipients on a complaint", %{conn: conn} do
      conn = post_resend(conn, "evt_c", "email.complained", ["spam@example.com"])

      assert json_response(conn, 200)["status"] == "ok"
      assert Suppression.suppressed?("spam@example.com")
    end

    test "ignores non-suppression events (e.g. delivered)", %{conn: conn} do
      conn = post_resend(conn, "evt_d", "email.delivered", ["fine@example.com"])

      assert json_response(conn, 200)["status"] == "ok"
      refute Suppression.suppressed?("fine@example.com")
    end
  end

  defp post_resend(conn, id, type, recipients) do
    payload = Jason.encode!(%{type: type, data: %{to: recipients}})
    ts = System.system_time(:second)
    sig = sign_resend(id, ts, payload)

    conn
    |> with_resend_headers(id, ts, sig)
    |> post("/webhooks/resend", payload)
  end

  defp with_resend_headers(conn, id, ts, sig) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("svix-id", id)
    |> put_req_header("svix-timestamp", "#{ts}")
    |> put_req_header("svix-signature", sig)
  end

  defp sign_resend(id, ts, payload) do
    secret =
      Application.fetch_env!(:engram, :resend_webhook_secret)
      |> String.replace_prefix("whsec_", "")
      |> Base.decode64!()

    mac = :crypto.mac(:hmac, :sha256, secret, "#{id}.#{ts}.#{payload}") |> Base.encode64()
    "v1,#{mac}"
  end
end
