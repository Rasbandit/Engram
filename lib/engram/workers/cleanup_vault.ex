defmodule Engram.Workers.CleanupVault do
  @moduledoc """
  Oban worker: hard-deletes all data for a soft-deleted vault after the retention period.

  Scheduled 30 days after soft-delete. If the vault has been restored (deleted_at cleared)
  or doesn't exist, the job is a no-op.

  Cleanup order:
  1. Qdrant points (best-effort, non-fatal)
  2. Storage blobs for attachments (best-effort, non-fatal)
  3. DB records in a transaction: chunks → notes → attachments → api_key_vaults → vault
  """

  use Oban.Worker, queue: :cleanup, max_attempts: 3

  require Logger

  import Ecto.Query

  alias Engram.Attachments.Attachment
  alias Engram.Notes.{Chunk, Note}
  alias Engram.Repo
  alias Engram.Vaults.Vault

  @retention_days 30

  @doc """
  Enqueues a CleanupVault job scheduled 30 days from now.
  """
  def enqueue(vault_id, user_id) do
    %{vault_id: vault_id, user_id: user_id}
    |> new(scheduled_at: DateTime.add(DateTime.utc_now(), @retention_days, :day))
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"vault_id" => vault_id, "user_id" => user_id}}) do
    perform_cleanup(vault_id, user_id)
  end

  @doc false
  def perform_cleanup(vault_id, _user_id) do
    vault = Repo.get(Vault, vault_id, skip_tenant_check: true)

    cond do
      is_nil(vault) ->
        Logger.info("CleanupVault: vault #{vault_id} not found — skipping")
        :ok

      is_nil(vault.deleted_at) ->
        Logger.info("CleanupVault: vault #{vault_id} was restored — skipping")
        :ok

      true ->
        Logger.info("CleanupVault: starting hard-delete for vault #{vault_id}")
        run_cleanup(vault)
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp run_cleanup(vault) do
    delete_qdrant_points(vault)
    delete_storage_blobs(vault)

    Repo.transaction(fn ->
      vault_id = vault.id

      Chunk
      |> where(vault_id: ^vault_id)
      |> Repo.delete_all(skip_tenant_check: true)

      Note
      |> where(vault_id: ^vault_id)
      |> Repo.delete_all(skip_tenant_check: true)

      Attachment
      |> where(vault_id: ^vault_id)
      |> Repo.delete_all(skip_tenant_check: true)

      from(akv in "api_key_vaults", where: akv.vault_id == ^vault_id)
      |> Repo.delete_all(skip_tenant_check: true)

      Repo.delete!(vault)
    end)

    Logger.info("CleanupVault: completed hard-delete for vault #{vault.id}")
    :ok
  end

  defp delete_qdrant_points(vault) do
    case Engram.Vector.Qdrant.delete_by_vault(to_string(vault.user_id), to_string(vault.id)) do
      :ok ->
        Logger.info("CleanupVault: deleted Qdrant points for vault #{vault.id}")

      {:error, reason} ->
        Logger.warning(
          "CleanupVault: Qdrant delete failed for vault #{vault.id}: #{inspect(reason)}"
        )
    end
  rescue
    e ->
      Logger.warning("CleanupVault: Qdrant delete raised for vault #{vault.id}: #{inspect(e)}")
  end

  defp delete_storage_blobs(vault) do
    keys =
      Attachment
      |> where(vault_id: ^vault.id)
      |> where([a], not is_nil(a.storage_key))
      |> select([a], a.storage_key)
      |> Repo.all(skip_tenant_check: true)

    Enum.each(keys, &delete_storage_blob/1)
  end

  defp delete_storage_blob(key) do
    case Engram.Storage.adapter().delete(key) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "CleanupVault: storage delete failed for key #{key}: #{inspect(reason)}"
        )
    end
  rescue
    e ->
      Logger.warning("CleanupVault: storage delete raised for key #{key}: #{inspect(e)}")
  end
end
