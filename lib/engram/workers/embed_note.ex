defmodule Engram.Workers.EmbedNote do
  @moduledoc """
  Oban worker: embeds a note and upserts to Qdrant.

  Debounce: 5-second scheduled_at delay, replaced on re-insert so rapid edits
  trigger only one Voyage API call.

  Dedup: unique per note_id in available/scheduled states, 60-second window.
  """

  use Oban.Worker,
    queue: :embed,
    max_attempts: 5,
    unique: [
      period: 60,
      keys: [:note_id],
      states: [:available, :scheduled]
    ]

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

      note ->
        case Indexing.index_note(note) do
          {:ok, _count} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
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
