defmodule Engram.Workers.DecryptVault do
  @moduledoc "Oban worker: restore plaintext for a vault. Implemented in Task 9."
  use Oban.Worker, queue: :crypto_backfill, max_attempts: 5

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: :ok
end
