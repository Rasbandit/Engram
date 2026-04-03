defmodule Engram.Embedders.Ollama do
  @moduledoc """
  Ollama embedder adapter for self-hosted inference.
  Uses the /api/embed endpoint (Ollama 0.3+).
  Reads config: OLLAMA_URL (default http://localhost:11434), EMBED_MODEL (nomic-embed-text).
  """

  @behaviour Engram.Embedder

  @default_url "http://localhost:11434"
  @default_model "nomic-embed-text"

  @impl true
  def embed_texts(texts) when is_list(texts) do
    url = System.get_env("OLLAMA_URL", @default_url)
    model = Application.get_env(:engram, :embed_model, @default_model)

    result =
      Req.post("#{url}/api/embed",
        json: %{model: model, input: texts},
        receive_timeout: 120_000
      )

    case result do
      {:ok, %{status: 200, body: %{"embeddings" => vectors}}} ->
        {:ok, vectors}

      {:ok, %{status: status, body: body}} ->
        {:error, {status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
