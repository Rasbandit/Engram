defmodule Engram.Workers.EncryptVault do
  @moduledoc "Oban worker: backfill-encrypts notes in a vault. Implemented in Task 8."
  use Oban.Worker, queue: :crypto_backfill, max_attempts: 5

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: :ok
end
