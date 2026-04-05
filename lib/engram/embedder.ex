defmodule Engram.Embedder do
  @moduledoc """
  Behaviour for embedding adapters (Voyage AI, Ollama, OpenAI, etc.).
  Implementations must accept a list of texts and return a list of float vectors.
  """

  @doc """
  Embed a batch of texts. Returns vectors in the same order as inputs.
  """
  @callback embed_texts([String.t()]) :: {:ok, [[float()]]} | {:error, term()}

  @doc """
  Returns metadata about the embedder: model name and vector dimensions.
  Used for collection setup and diagnostics.
  """
  @callback model_info() :: %{model: String.t(), dimensions: pos_integer()}

  @optional_callbacks [model_info: 0]
end
