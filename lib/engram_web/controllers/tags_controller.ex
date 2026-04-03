defmodule EngramWeb.TagsController do
  use EngramWeb, :controller

  alias Engram.Notes

  def index(conn, _params) do
    {:ok, tags} = Notes.list_tags(conn.assigns.current_user)
    json(conn, %{tags: tags})
  end
end
