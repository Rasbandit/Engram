defmodule Engram.Workers.ReconcileEmbeddings do
  @moduledoc """
  Oban cron worker: finds notes with stale or missing embeddings and re-queues them.

  Runs every 15 minutes via Oban.Plugins.Cron. Catches any notes that fell through
  the cracks — failed jobs, discarded jobs, config errors, crashes mid-embed.

  A note needs embedding when:
  - embed_hash IS NULL (never embedded)
  - embed_hash != content_hash (content changed since last embed)
  - not soft-deleted

  Uses the partial index idx_notes_embed_pending for fast lookups.
  Batches to avoid flooding the embed queue.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: [period: 300, states: [:available, :scheduled, :executing]]

  import Ecto.Query

  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Workers.EmbedNote

  @batch_size 100

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    note_ids =
      from(n in Note,
        where:
          is_nil(n.deleted_at) and
            (is_nil(n.embed_hash) or n.embed_hash != n.content_hash),
        select: n.id,
        limit: @batch_size
      )
      |> Repo.all(skip_tenant_check: true)

    if note_ids != [] do
      jobs = Enum.map(note_ids, &EmbedNote.new_debounced/1)
      Oban.insert_all(jobs)
    end

    :ok
  end
end
