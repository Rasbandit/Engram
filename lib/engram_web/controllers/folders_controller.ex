defmodule EngramWeb.FoldersController do
  use EngramWeb, :controller

  alias Engram.Notes

  def index(conn, _params) do
    {:ok, folders} = Notes.list_folders(conn.assigns.current_user)
    json(conn, %{folders: folders})
  end
end
