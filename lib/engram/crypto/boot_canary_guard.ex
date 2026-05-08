defmodule Engram.Crypto.BootCanaryGuard do
  @moduledoc """
  Supervised guard that runs `Engram.Crypto.BootCanary.verify!/0` synchronously
  during `Application.start/2`, after `Engram.Repo` is up, and propagates
  failure as a `start_link` error so the whole application start fails.

  T3-audit C2 — the prior wiring used `Task.start_link` with
  `restart: :temporary`. `Task.start_link/1` returns `{:ok, pid}` the moment
  the task is spawned, so any later raise inside `verify!/0` lands in the
  task process where `:temporary` causes the supervisor to log the EXIT and
  take no further action. Result: app booted with the WRONG master key,
  defeating the entire purpose of T3.5/M3.

  This module fixes that by running `verify!/0` inside `init/1`. If it
  raises, `GenServer.start_link/3` returns `{:error, reason}`, the parent
  supervisor's `start_link` returns `{:error, _}`, and `Application.start/2`
  fails — the VM exits non-zero. True fail-loud.

  On success, `init/1` returns `:ignore` so no process is kept around (the
  canary check has no ongoing duties).

  Skipped entirely when `:boot_canary_enabled` is false (e.g. `:test`,
  where the canary table is per-sandbox and tests cover the underlying
  `BootCanary` module directly).
  """

  use GenServer

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [])
  end

  @impl true
  def init(_) do
    Engram.Crypto.BootCanary.verify!()
    :ignore
  end
end
