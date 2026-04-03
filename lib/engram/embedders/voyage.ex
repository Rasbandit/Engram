defmodule Engram.Embedders.Voyage do
  @moduledoc """
  Voyage AI embedder adapter. Calls the Voyage AI REST API via Req.
  Reads config: VOYAGE_API_KEY, EMBED_MODEL (default voyage-4-large).
  """

  @behaviour Engram.Embedder

  @default_url "https://api.voyageai.com"
  @default_model "voyage-4-large"

  @impl true
  def model_info do
    %{
      model: Application.get_env(:engram, :embed_model, @default_model),
      dimensions: Application.get_env(:engram, :embed_dims, 1024)
    }
  end

  @impl true
  def embed_texts(texts) when is_list(texts) do
    url = Application.get_env(:engram, :voyage_url, @default_url)
    model = Application.get_env(:engram, :embed_model, @default_model)
    api_key = System.get_env("VOYAGE_API_KEY") ||
      raise "VOYAGE_API_KEY environment variable is not set"

    result =
      Req.post("#{url}/v1/embeddings",
        json: %{input: texts, model: model},
        headers: [{"authorization", "Bearer #{api_key}"}],
        receive_timeout: 30_000
      )

    case result do
      {:ok, %{status: 200, body: %{"data" => data}}} ->
        vectors = Enum.map(data, & &1["embedding"])
        {:ok, vectors}

      {:ok, %{status: status, body: body}} ->
        {:error, {status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
