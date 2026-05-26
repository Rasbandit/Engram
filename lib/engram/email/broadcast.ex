defmodule Engram.Email.Broadcast do
  @moduledoc """
  Batch-send an OG-waitlist grandfather template to a list of recipients.
  Backs `mix engram.email.broadcast`.

  Defaults to a dry-run (count only, no sends); pass `send?: true` to actually
  send. Resend has no bulk-HTML endpoint, so this sends one request per
  recipient — failures are collected and returned rather than raised, and an
  optional `:throttle_ms` paces sends under Resend's rate limit.
  """

  alias Engram.Mailer

  @type row :: %{email: String.t(), name: String.t()}
  @type result :: %{
          optional(:dry_run) => true,
          optional(:recipients) => non_neg_integer(),
          sent: non_neg_integer(),
          failed: [{String.t(), term()}]
        }

  @spec run(:og1 | :og2 | :og3, [row()], keyword()) :: result()
  def run(template, rows, opts \\ []) do
    if Keyword.get(opts, :send?, false) do
      send_all(template, rows, opts)
    else
      %{dry_run: true, recipients: length(rows), sent: 0, failed: []}
    end
  end

  defp send_all(template, rows, opts) do
    throttle_ms = Keyword.get(opts, :throttle_ms, 0)

    rows
    |> Enum.reduce(%{sent: 0, failed: []}, fn row, acc ->
      result =
        case send_one(template, row, opts) do
          :ok -> %{acc | sent: acc.sent + 1}
          {:error, reason} -> %{acc | failed: acc.failed ++ [{row.email, reason}]}
        end

      if throttle_ms > 0, do: Process.sleep(throttle_ms)
      result
    end)
  end

  defp send_one(:og1, %{email: email, name: name}, opts),
    do: Mailer.send_og_grandfather_1(email, name, Keyword.fetch!(opts, :checkout_url))

  defp send_one(:og2, %{email: email, name: name}, opts),
    do:
      Mailer.send_og_grandfather_2(
        email,
        name,
        Keyword.fetch!(opts, :expiry_date),
        Keyword.fetch!(opts, :portal_url)
      )

  defp send_one(:og3, %{email: email, name: name}, _opts),
    do: Mailer.send_og_grandfather_3(email, name)
end
