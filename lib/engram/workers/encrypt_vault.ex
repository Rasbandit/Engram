defmodule Engram.Workers.EncryptVault do
  @moduledoc """
  Backfill-encrypts every note in a vault. Batch of 100 per job invocation,
  per-note atomicity (Postgres transaction + idempotent Qdrant set_payload),
  cursor-resumable on crash. Re-enqueues itself until the final batch,
  then flips vault status to "encrypted".
  """

  use Oban.Worker,
    queue: :crypto_backfill,
    max_attempts: 5,
    unique: [keys: [:vault_id], states: [:available, :scheduled, :executing]]

  import Ecto.Query
  require Logger

  alias Engram.Accounts.User
  alias Engram.Crypto
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Vaults.Vault

  @batch_size 100

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"vault_id" => vault_id, "user_id" => user_id, "cursor" => cursor}}) do
    Repo.with_tenant(user_id, fn ->
      vault = Repo.get!(Vault, vault_id)
      user = Repo.get!(User, user_id)

      if vault.encryption_status != "encrypting" do
        Logger.info("EncryptVault no-op: vault #{vault_id} status=#{vault.encryption_status}")
        :ok
      else
        with {:ok, user} <- Crypto.ensure_user_dek(user) do
          process_batch(vault, user, cursor)
        end
      end
    end)
    |> case do
      {:ok, result} -> result
      other -> other
    end
  end

  defp process_batch(vault, user, cursor) do
    notes =
      from(n in Note,
        where: n.vault_id == ^vault.id and n.id > ^cursor,
        order_by: [asc: n.id],
        limit: @batch_size
      )
      |> Repo.all()

    case Enum.reduce_while(notes, {:ok, cursor}, &encrypt_note(&1, &2, user, vault)) do
      {:ok, last_id} ->
        if length(notes) == @batch_size do
          {:ok, _} =
            __MODULE__.new(%{
              vault_id: vault.id,
              user_id: user.id,
              cursor: last_id
            })
            |> Oban.insert()

          :ok
        else
          finalize_vault(vault, length(notes))
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp encrypt_note(%Note{} = note, {:ok, _last}, user, vault) do
    started_at = System.monotonic_time()

    # Qdrant indexing runs against the plaintext note so Markdown.parse can
    # produce chunks. Postgres encryption then stamps ciphertext columns
    # (plaintext fields are cleared only in the DB row).
    with :ok <- encrypt_qdrant(note, vault),
         {:ok, _encrypted_note} <- encrypt_postgres(note, user, vault) do
      duration = System.monotonic_time() - started_at

      :telemetry.execute(
        [:engram, :crypto, :backfill, :note_encrypted],
        %{duration: duration},
        %{vault_id: vault.id, note_id: note.id}
      )

      {:cont, {:ok, note.id}}
    else
      {:error, reason} ->
        Logger.error("EncryptVault failed note #{note.id}: #{inspect(reason)}")
        {:halt, {:error, reason}}
    end
  end

  defp encrypt_postgres(%Note{} = note, user, vault) do
    attrs = %{
      content: note.content || "",
      title: note.title,
      tags: note.tags
    }

    case Crypto.maybe_encrypt_note_fields(attrs, user, vault) do
      {:ok, encrypted_attrs} ->
        note
        |> Note.encryption_changeset(encrypted_attrs)
        |> Repo.update()

      error ->
        error
    end
  end

  defp encrypt_qdrant(%Note{} = note, vault) do
    case Engram.Indexing.index_note(note, vault) do
      {:ok, _} -> :ok
      :ok -> :ok
      error -> error
    end
  end

  defp finalize_vault(vault, processed_count) do
    locked = Repo.get!(Vault, vault.id, lock: "FOR UPDATE")

    if locked.encryption_status == "encrypting" do
      locked
      |> Ecto.Changeset.change(%{
        encryption_status: "encrypted",
        encrypted_at: DateTime.utc_now()
      })
      |> Repo.update!()
    end

    :telemetry.execute(
      [:engram, :crypto, :backfill, :vault_encrypted],
      %{processed: processed_count},
      %{vault_id: vault.id}
    )

    :ok
  end
end
