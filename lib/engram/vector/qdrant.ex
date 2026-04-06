defmodule Engram.Vector.Qdrant do
  @moduledoc """
  Thin Req-based HTTP wrapper for the Qdrant REST API.
  All operations target a single collection.

  Config:
  - :qdrant_url — base URL (default http://localhost:6333)
  - QDRANT_API_KEY env var — API key for Qdrant Cloud (optional for local)
  """

  @default_url "http://localhost:6333"
  @default_collection "engram_notes"

  defp base_url, do: Application.get_env(:engram, :qdrant_url, @default_url)
  defp collection, do: Application.get_env(:engram, :qdrant_collection, @default_collection)

  defp req_opts do
    base = [receive_timeout: 30_000, retry: :transient, max_retries: 3, connect_options: [protocols: [:http1]]]

    case System.get_env("QDRANT_API_KEY") do
      nil -> base
      key -> Keyword.put(base, :headers, [{"api-key", key}])
    end
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Ensure a collection exists with the given vector dimensions.
  Creates it if missing; no-ops if already present (Qdrant returns 200 either way).
  """
  def ensure_collection(col \\ nil, dims) do
    col = col || collection()

    opts =
      [
        json: %{
          vectors: %{size: dims, distance: "Cosine"},
          quantization_config: %{
            binary: %{
              always_ram: true
            }
          }
        }
      ] ++ req_opts()

    case Req.put("#{base_url()}/collections/#{col}", opts) do
      {:ok, %{status: status}} when status in [200, 201, 409] -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Delete a collection. Idempotent: returns `:ok` for both 200 and 404.
  """
  def delete_collection(col) do
    opts = req_opts()

    case Req.delete("#{base_url()}/collections/#{col}", opts) do
      {:ok, %{status: status}} when status in [200, 404] -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Get collection info. Returns the raw `result` map from Qdrant
  (includes config, point count, etc.).
  """
  def collection_info(col) do
    opts = req_opts()

    case Req.get("#{base_url()}/collections/#{col}", opts) do
      {:ok, %{status: 200, body: %{"result" => result}}} -> {:ok, result}
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Upsert a batch of points. Each point: %{id: uuid_string, vector: [float], payload: map}.
  """
  def upsert_points(col \\ nil, points) do
    col = col || collection()

    serialized = Enum.map(points, fn p -> %{id: p.id, vector: p.vector, payload: p.payload} end)
    opts = [json: %{points: serialized}] ++ req_opts()

    case Req.put("#{base_url()}/collections/#{col}/points", opts) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Delete all points for a given user+path combination.
  """
  def delete_by_note(col \\ nil, user_id, path) do
    col = col || collection()

    filter = %{
      must: [
        %{key: "user_id", match: %{value: user_id}},
        %{key: "source_path", match: %{value: path}}
      ]
    }

    opts = [json: %{filter: filter}] ++ req_opts()

    case Req.post("#{base_url()}/collections/#{col}/points/delete", opts) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Vector similarity search. Returns list of result structs with score + payload.

  Options:
  - `:user_id` — filter to this user's points (required for tenant isolation)
  - `:limit`   — number of results (default 5)
  - `:tags`    — filter to points with ANY of these tags
  - `:folder`  — filter to points in this folder
  """
  def search(col \\ nil, vector, search_opts) do
    col = col || collection()
    user_id = Keyword.fetch!(search_opts, :user_id)
    limit = Keyword.get(search_opts, :limit, 5)
    tags = Keyword.get(search_opts, :tags)
    folder = Keyword.get(search_opts, :folder)

    must = [%{key: "user_id", match: %{value: user_id}}]
    must = if tags, do: [%{key: "tags", match: %{any: tags}} | must], else: must
    must = if folder, do: [%{key: "folder", match: %{value: folder}} | must], else: must

    body = %{
      query: vector,
      filter: %{must: must},
      limit: limit,
      with_payload: true,
      params: %{
        quantization: %{
          rescore: true,
          oversampling: 3.0
        }
      }
    }
    opts = [json: body] ++ req_opts()

    case Req.post("#{base_url()}/collections/#{col}/points/query", opts) do
      {:ok, %{status: 200, body: %{"result" => result}}} ->
        points = if is_list(result), do: result, else: result["points"] || []

        results =
          Enum.map(points, fn p ->
            %{
              score: p["score"],
              text: get_in(p, ["payload", "text"]),
              title: get_in(p, ["payload", "title"]),
              heading_path: get_in(p, ["payload", "heading_path"]),
              source_path: get_in(p, ["payload", "source_path"]),
              tags: get_in(p, ["payload", "tags"]) || [],
              qdrant_id: p["id"]
            }
          end)

        {:ok, results}

      {:ok, %{status: status, body: body}} ->
        {:error, {status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
