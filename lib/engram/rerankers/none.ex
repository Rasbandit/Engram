defmodule Engram.Rerankers.None do
  @moduledoc """
  Passthrough reranker — returns candidates sorted by vector score only.
  Used when no external reranker is configured.
  """

  @behaviour Engram.Reranker

  @impl true
  def rerank(_query, candidates, top_n) do
    {:ok, candidates |> Enum.sort_by(& &1.score, :desc) |> Enum.take(top_n)}
  end
end
