defmodule Engram.Indexing do
  @moduledoc """
  Orchestrates the parse → embed → upsert pipeline.

  Called from EmbedNote worker (async, after note upsert).
  Uses the configured embedder adapter and Qdrant client.
  """

  import Ecto.Query

  alias Engram.Notes.Chunk
  alias Engram.Parsers.Markdown
  alias Engram.Repo
  alias Engram.Vector.Qdrant

  @default_dims 1024

  defp collection, do: Application.get_env(:engram, :qdrant_collection, "engram_notes")
  defp embedder, do: Application.get_env(:engram, :embedder, Engram.Embedders.Voyage)

  @doc """
  Full pipeline for a note: parse → embed → delete old chunks → upsert new chunks.
  Returns {:ok, chunk_count} or {:error, reason}.
  """
  def index_note(note) do
    chunks = Markdown.parse(note.content || "", note.path)

    if chunks == [] do
      {:ok, 0}
    else
      context_texts = Enum.map(chunks, & &1.context_text)
      dims = Application.get_env(:engram, :embed_dims, @default_dims)

      with :ok <- Qdrant.ensure_collection(collection(), dims),
           {:ok, vectors} <- embed_for_indexing(context_texts),
           :ok <- replace_chunks(note, chunks, vectors) do
        {:ok, length(chunks)}
      end
    end
  end

  @doc """
  Delete Qdrant points for a specific path (used after rename to clean up old path).
  """
  def delete_points_by_path(note, path) do
    Qdrant.delete_by_note(collection(), to_string(note.user_id), path)
  end

  @doc """
  Remove all indexed data for a note (Qdrant points first, then Postgres chunks).
  """
  def delete_note_index(note) do
    with :ok <- Qdrant.delete_by_note(collection(), to_string(note.user_id), note.path) do
      Repo.delete_all(from(c in Chunk, where: c.note_id == ^note.id), skip_tenant_check: true)
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp doc_embed_model, do: Application.get_env(:engram, :doc_embed_model)

  defp embed_for_indexing(texts) do
    case doc_embed_model() do
      nil -> embedder().embed_texts(texts)
      model -> embedder().embed_texts(texts, model: model)
    end
  end

  defp replace_chunks(note, chunks, vectors) do
    # Delete from Qdrant first (external, idempotent) — if this fails, Postgres is untouched
    with :ok <- Qdrant.delete_by_note(collection(), to_string(note.user_id), note.path) do
      # skip_tenant_check: trusted internal pipeline, already scoped by note_id/user_id
      Repo.delete_all(from(c in Chunk, where: c.note_id == ^note.id), skip_tenant_check: true)

      # Build new chunk rows + Qdrant points
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      chunk_rows =
        Enum.zip(chunks, vectors)
        |> Enum.map(fn {chunk, _vector} ->
          point_id = Ecto.UUID.generate()

          %{
            note_id: note.id,
            user_id: note.user_id,
            position: chunk.position,
            heading_path: chunk.heading_path,
            char_start: chunk.char_start,
            char_end: chunk.char_end,
            qdrant_point_id: point_id,
            created_at: now
          }
        end)

      {_, inserted} =
        Repo.insert_all(Chunk, chunk_rows,
          returning: [:id, :qdrant_point_id, :position],
          skip_tenant_check: true
        )

      qdrant_points =
        Enum.zip(inserted, Enum.zip(chunks, vectors))
        |> Enum.map(fn {row, {chunk, vector}} ->
          %{
            id: row.qdrant_point_id,
            vector: vector,
            payload: %{
              user_id: to_string(note.user_id),
              source_path: note.path,
              title: note.title,
              folder: note.folder || "",
              tags: note.tags || [],
              heading_path: chunk.heading_path,
              text: chunk.text,
              chunk_index: row.position
            }
          }
        end)

      Qdrant.upsert_points(collection(), qdrant_points)
    end
  end
end
