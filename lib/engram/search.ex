defmodule Engram.Search do
  @moduledoc """
  Vector search: embed query → Qdrant similarity → return ranked results.
  Supports optional folder and tag filters.
  """

  alias Engram.Vector.Qdrant

  defp collection, do: Application.get_env(:engram, :qdrant_collection, "obsidian_notes")

  defp embedder, do: Application.get_env(:engram, :embedder, Engram.Embedders.Voyage)

  @doc """
  Search notes for a user. Returns {:ok, results} where each result has:
  score, text, title, heading_path, source_path, tags.

  Options:
  - `:limit`  — number of results (default 5)
  - `:tags`   — filter to notes with any of these tags
  - `:folder` — filter to notes in this folder
  """
  def search(user, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)
    tags = Keyword.get(opts, :tags)
    folder = Keyword.get(opts, :folder)

    with {:ok, [vector]} <- embedder().embed_texts([query]) do
      search_opts =
        [user_id: to_string(user.id), limit: limit]
        |> then(&if(tags, do: Keyword.put(&1, :tags, tags), else: &1))
        |> then(&if(folder, do: Keyword.put(&1, :folder, folder), else: &1))

      Qdrant.search(collection(), vector, search_opts)
    end
  end
end
