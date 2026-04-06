defmodule Engram.Workers.EmbedNote do
  @moduledoc """
  Oban worker: embeds a note and upserts to Qdrant.

  Debounce: 5-second scheduled_at delay, replaced on re-insert so rapid edits
  trigger only one Voyage API call.

  Dedup: unique per note_id in available/scheduled states, 60-second window.

  Idempotency: skips embedding when embed_hash already matches content_hash
  (content hasn't changed since last successful embed). On success, sets
  embed_hash = content_hash using an optimistic lock — if content changed
  mid-embed, the update is a no-op and the next job picks up the new version.
  """

  use Oban.Worker,
    queue: :embed,
    max_attempts: 5,
    unique: [
      period: 60,
      keys: [:note_id],
      states: [:available, :scheduled]
    ]

  require Logger

  import Ecto.Query

  alias Engram.Indexing
  alias Engram.Notes.Note
  alias Engram.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"note_id" => note_id}}) do
    # skip_tenant_check: trusted internal worker — queries already scoped to note_id/user_id
    case Repo.get(Note, note_id, skip_tenant_check: true) do
      nil ->
        {:discard, "note #{note_id} not found"}

      %Note{deleted_at: deleted_at} when not is_nil(deleted_at) ->
        {:discard, "note #{note_id} is soft-deleted"}

      %Note{content_hash: hash, embed_hash: hash} when not is_nil(hash) ->
        # Already embedded this exact content — skip
        :ok

      note ->
        case Indexing.index_note(note) do
          {:ok, _count} ->
            stamp_embed_hash(note)
            :ok

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Optimistic lock: only set embed_hash if content_hash hasn't changed since
  # we started embedding. If it changed (concurrent edit), this is a no-op —
  # the reconciliation cron or the next debounced job will pick up the new version.
  defp stamp_embed_hash(%Note{content_hash: nil}), do: :ok

  defp stamp_embed_hash(note) do
    {count, _} =
      from(n in Note,
        where: n.id == ^note.id and n.content_hash == ^note.content_hash
      )
      |> Repo.update_all([set: [embed_hash: note.content_hash]], skip_tenant_check: true)

    if count == 0 do
      Logger.info("embed_hash stamp skipped (concurrent edit): note_id=#{note.id}")
    end

    :ok
  end

  @doc """
  Build an Oban job with 5-second debounce.
  `replace: [:scheduled_at]` resets the timer on rapid edits (dedup by note_id).
  """
  def new_debounced(note_id) do
    scheduled_at = DateTime.add(DateTime.utc_now(), 5, :second)

    new(
      %{note_id: note_id},
      scheduled_at: scheduled_at,
      replace: [:scheduled_at]
    )
  end
end
