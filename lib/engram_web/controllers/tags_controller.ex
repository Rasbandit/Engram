defmodule EngramWeb.TagsController do
  use EngramWeb, :controller

  alias Engram.Notes

  def index(conn, _params) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault
    {:ok, tags} = Notes.list_tags(user, vault)
    json(conn, %{tags: Enum.map(tags, &%{name: &1})})
  end
end
