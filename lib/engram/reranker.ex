defmodule Engram.Reranker do
  @moduledoc """
  Behaviour for reranker adapters (Jina, Cohere, None).
  Implementations take vector search candidates, rerank them, and return top N.
  """

  @type candidate :: map()

  @doc """
  Rerank a list of search candidates for a query.
  Returns {:ok, top_n_results} — must always succeed (fallback to input order on failure).
  """
  @callback rerank(query :: String.t(), candidates :: [candidate()], top_n :: pos_integer()) ::
              {:ok, [candidate()]}
end
