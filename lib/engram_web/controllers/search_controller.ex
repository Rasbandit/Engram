defmodule EngramWeb.SearchController do
  use EngramWeb, :controller

  alias Engram.Search

  def search(conn, %{"query" => query} = params) do
    user = conn.assigns.current_user
    limit = params["limit"] || 5
    tags = params["tags"]
    folder = params["folder"]

    opts =
      [limit: limit]
      |> then(&if(tags, do: Keyword.put(&1, :tags, tags), else: &1))
      |> then(&if(folder, do: Keyword.put(&1, :folder, folder), else: &1))

    case Search.search(user, query, opts) do
      {:ok, results} ->
        json(conn, %{results: results})

      {:error, reason} ->
        conn
        |> put_status(500)
        |> json(%{error: inspect(reason)})
    end
  end

  def search(conn, _params) do
    conn
    |> put_status(422)
    |> json(%{error: "query is required"})
  end
end
