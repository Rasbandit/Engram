defmodule Engram.Embedder do
  @moduledoc """
  Behaviour for embedding adapters (Voyage AI, Ollama).
  Implementations must accept a list of texts and return a list of float vectors.
  """

  @doc """
  Embed a batch of texts. Returns vectors in the same order as inputs.
  """
  @callback embed_texts([String.t()]) :: {:ok, [[float()]]} | {:error, term()}
end
