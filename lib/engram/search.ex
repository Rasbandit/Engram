defmodule Engram.Search do
  @moduledoc """
  Two-stage search: embed query → Qdrant similarity (4x candidates) →
  reranker (blend scores) → return top N results.

  Both embedder and reranker are config-driven behaviours:
  - `:embedder`  — Engram.Embedders.Voyage | .Ollama | any Engram.Embedder impl
  - `:reranker`  — Engram.Rerankers.Jina | .None | any Engram.Reranker impl
  """

  alias Engram.Vector.Qdrant

  @min_candidates 20

  defp collection, do: Application.get_env(:engram, :qdrant_collection, "engram_notes")

  defp embedder, do: Application.get_env(:engram, :embedder, Engram.Embedders.Voyage)

  defp reranker, do: Application.get_env(:engram, :reranker, Engram.Rerankers.None)

  defp reranker_active?, do: reranker() != Engram.Rerankers.None

  defp query_embed_model, do: Application.get_env(:engram, :query_embed_model)

  defp embed_for_search(query) do
    case query_embed_model() do
      nil -> embedder().embed_texts([query])
      model -> embedder().embed_texts([query], model: model)
    end
  end

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

    # Fetch more candidates when reranking is active
    fetch_limit = if reranker_active?(), do: max(limit * 4, @min_candidates), else: limit

    with {:ok, [vector]} <- embed_for_search(query) do
      search_opts =
        [user_id: to_string(user.id), limit: fetch_limit]
        |> then(&if(tags, do: Keyword.put(&1, :tags, tags), else: &1))
        |> then(&if(folder, do: Keyword.put(&1, :folder, folder), else: &1))

      with {:ok, candidates} <- Qdrant.search(collection(), vector, search_opts) do
        reranker().rerank(query, candidates, limit)
      end
    end
  end
end
