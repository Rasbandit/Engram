defmodule EngramWeb.SearchController do
  use EngramWeb, :controller

  alias Engram.Search

  @max_search_limit 50

  def search(conn, %{"query" => query} = params) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault
    limit = params["limit"] |> clamp_limit()
    tags = params["tags"]
    folder = params["folder"]
    cross_vault = Map.get(params, "cross_vault", false)

    opts =
      [limit: limit, cross_vault: cross_vault]
      |> then(&if(tags, do: Keyword.put(&1, :tags, tags), else: &1))
      |> then(&if(folder, do: Keyword.put(&1, :folder, folder), else: &1))

    case Search.search(user, vault, query, opts) do
      {:ok, results} ->
        json(conn, %{results: results})

      {:error, :feature_not_available} ->
        conn
        |> put_status(403)
        |> json(%{error: "Cross-vault search requires Pro plan"})

      {:error, reason} ->
        require Logger
        Logger.error("Search failed: #{inspect(reason)}")

        conn
        |> put_status(500)
        |> json(%{error: "search_failed", detail: inspect(reason)})
    end
  end

  def search(conn, _params) do
    conn
    |> put_status(422)
    |> json(%{error: "query is required"})
  end

  defp clamp_limit(nil), do: 5
  defp clamp_limit(n) when is_integer(n), do: n |> max(1) |> min(@max_search_limit)

  defp clamp_limit(n) when is_binary(n) do
    case Integer.parse(n) do
      {int, ""} -> clamp_limit(int)
      _ -> 5
    end
  end

  defp clamp_limit(_), do: 5
end
