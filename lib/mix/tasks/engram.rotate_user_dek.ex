defmodule Mix.Tasks.Engram.RotateUserDek do
  @moduledoc """
  T3.7 — operator entry point for per-user DEK rotation.

  ## Usage

      mix engram.rotate_user_dek --user-id 42

  Synchronous: blocks until the user's data is fully re-encrypted under
  a new DEK. The user is read+write locked for the duration; clients
  receive HTTP 503 + `Retry-After: 60`.

  The new dek_version is chosen internally (`current + 1`). Operators
  do not specify a target — re-running rotates again to a fresh
  version. See runbook in
  `docs/context/encryption-operations.md` § T3.7.4.

  ## Pre-flight checklist

  1. Confirm no other rotation is in flight:
       SELECT id FROM users WHERE dek_rotation_locked_at IS NOT NULL;

  2. Capture current dek_version (rollback reference):
       SELECT id, dek_version FROM users WHERE id = :user_id;

  3. Run the command. Watch telemetry
     `engram.crypto.rotate.dek.count` (`status=ok`/`failed`).
  """

  use Mix.Task

  alias Engram.Crypto.UserDekRotation

  @shortdoc "Rotate one user's DEK, re-encrypting all their data under a fresh key"

  @switches [user_id: :integer]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args, switches: @switches)
    user_id = Keyword.fetch!(opts, :user_id)

    IO.puts("rotating DEK for user_id=#{user_id}...")

    case UserDekRotation.rotate_user(user_id) do
      :ok ->
        IO.puts("rotation complete: user_id=#{user_id}")
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "ERROR: rotation failed user_id=#{user_id} reason=#{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end
end
