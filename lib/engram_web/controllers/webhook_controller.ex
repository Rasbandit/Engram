defmodule EngramWeb.WebhookController do
  use EngramWeb, :controller

  alias Engram.Billing

  def stripe(conn, _params) do
    with {:ok, sig_header} <- get_signature(conn),
         {:ok, payload} <- read_body_once(conn),
         :ok <- verify_signature(payload, sig_header) do
      event = Jason.decode!(payload)
      Billing.upsert_from_stripe_event(event)
      json(conn, %{status: "ok"})
    else
      {:error, reason} ->
        conn
        |> put_status(400)
        |> json(%{error: to_string(reason)})
    end
  end

  defp get_signature(conn) do
    case Plug.Conn.get_req_header(conn, "stripe-signature") do
      [sig] -> {:ok, sig}
      _ -> {:error, "missing stripe-signature header"}
    end
  end

  defp read_body_once(conn) do
    case conn.assigns[:raw_body] do
      nil -> {:error, "no raw body available"}
      body -> {:ok, body}
    end
  end

  defp verify_signature(payload, sig_header) do
    secret = Application.get_env(:engram, :stripe_webhook_secret)

    with {:ok, timestamp} <- extract_timestamp(sig_header),
         {:ok, expected_sig} <- extract_v1_signature(sig_header) do
      signed_payload = "#{timestamp}.#{payload}"

      computed =
        :crypto.mac(:hmac, :sha256, secret, signed_payload)
        |> Base.encode16(case: :lower)

      if Plug.Crypto.secure_compare(computed, expected_sig) do
        :ok
      else
        {:error, "invalid signature"}
      end
    end
  end

  defp extract_timestamp(header) do
    case Regex.run(~r/t=(\d+)/, header) do
      [_, ts] -> {:ok, ts}
      _ -> {:error, "invalid signature format"}
    end
  end

  defp extract_v1_signature(header) do
    case Regex.run(~r/v1=([a-f0-9]+)/, header) do
      [_, sig] -> {:ok, sig}
      _ -> {:error, "invalid signature format"}
    end
  end
end
