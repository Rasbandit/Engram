defmodule EngramWeb.FoldersController do
  use EngramWeb, :controller

  alias Engram.Notes

  def index(conn, _params) do
    {:ok, folders} = Notes.list_folders(conn.assigns.current_user)
    json(conn, %{folders: folders})
  end

  def list(conn, %{"folder" => folder}) do
    user = conn.assigns.current_user
    {:ok, notes} = Notes.list_notes_in_folder(user, folder)

    json(conn, %{
      notes: Enum.map(notes, &note_summary/1)
    })
  end

  def list(conn, _params) do
    conn |> put_status(400) |> json(%{error: "folder parameter is required"})
  end

  def rename(conn, %{"old_folder" => old_folder, "new_folder" => new_folder}) do
    user = conn.assigns.current_user
    {:ok, count} = Notes.rename_folder(user, old_folder, new_folder)
    json(conn, %{count: count})
  end

  defp note_summary(note) do
    %{
      path: note.path,
      title: note.title,
      folder: note.folder || "",
      tags: note.tags || [],
      version: note.version,
      mtime: note.mtime,
      updated_at: note.updated_at
    }
  end
end
