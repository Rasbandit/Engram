defmodule Engram.Telemetry.ObanDiscardHandler do
  @moduledoc """
  Telemetry handler that surfaces Oban job discards as warning-level log lines
  and re-emits a `[:engram, :oban, :discarded]` counter event.

  Oban emits `[:oban, :job, :exception]` for every job that ends in failure,
  cancellation, snooze, or discard. We only act on `state: :discarded` — the
  terminal state where Oban has burned `max_attempts` and dropped the work.
  These are the cases that need attention; transient `:failure` retries are
  expected and noisy.

  Wires from `Engram.Application.start/2` so the handler is live for the
  lifetime of the VM. Layer 3 of the embed/Voyage rate-limit defense work —
  Layer 1 (#284) and Layer 2 (#286) prevent the discard cascade; this handler
  makes the surviving cases visible without taking a new dep (PromEx/Sentry).

  Future PromEx/Sentry can attach to `[:engram, :oban, :discarded]` for
  alerting; the source event already carries `worker` and `queue` metadata.
  """

  require Logger

  @handler_id :engram_oban_discard
  @event [:oban, :job, :exception]

  @doc """
  Attach (or re-attach) the telemetry handler. Idempotent — detaches first so
  repeated boots (and ExUnit's per-suite restart) don't accumulate handlers.
  """
  def attach do
    _ = :telemetry.detach(@handler_id)

    :ok =
      :telemetry.attach(
        @handler_id,
        @event,
        &__MODULE__.handle_event/4,
        nil
      )
  end

  @doc false
  def handle_event(@event, _measurements, %{state: :discarded} = metadata, _config) do
    worker = metadata[:worker]
    queue = metadata[:queue]
    job = metadata[:job] || %{}
    reason = metadata[:reason]

    Logger.warning(
      "Oban job discarded after max_attempts: worker=#{worker} queue=#{inspect(queue)} job_id=#{inspect(Map.get(job, :id))} attempt=#{inspect(Map.get(job, :attempt))}/#{inspect(Map.get(job, :max_attempts))} reason=#{inspect(reason)}",
      worker: worker,
      queue: queue,
      job_id: Map.get(job, :id),
      attempt: Map.get(job, :attempt),
      max_attempts: Map.get(job, :max_attempts),
      reason_label: :oban_discarded
    )

    :telemetry.execute(
      [:engram, :oban, :discarded],
      %{count: 1},
      %{worker: worker, queue: queue, job_id: Map.get(job, :id)}
    )
  end

  def handle_event(@event, _measurements, _metadata, _config), do: :ok
end
