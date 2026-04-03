defmodule Engram.Search do
  @moduledoc """
  Two-stage search: embed query → Qdrant similarity (4x candidates) →
  optional Jina reranker (blend scores) → return top N results.
  Falls back to vector-only if reranker is unavailable.
  """

  alias Engram.Vector.Qdrant
  alias Engram.Rerankers.Jina

  @min_candidates 20

  defp collection, do: Application.get_env(:engram, :qdrant_collection, "obsidian_notes")

  defp embedder, do: Application.get_env(:engram, :embedder, Engram.Embedders.Voyage)

  defp reranker_enabled?, do: Application.get_env(:engram, :jina_url) != nil

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

    # Fetch more candidates when reranking
    fetch_limit = if reranker_enabled?(), do: max(limit * 4, @min_candidates), else: limit

    with {:ok, [vector]} <- embedder().embed_texts([query]) do
      search_opts =
        [user_id: to_string(user.id), limit: fetch_limit]
        |> then(&if(tags, do: Keyword.put(&1, :tags, tags), else: &1))
        |> then(&if(folder, do: Keyword.put(&1, :folder, folder), else: &1))

      with {:ok, candidates} <- Qdrant.search(collection(), vector, search_opts) do
        if candidates != [] and reranker_enabled?() do
          Jina.rerank(query, candidates, limit)
        else
          {:ok, Enum.take(candidates, limit)}
        end
      end
    end
  end
end
