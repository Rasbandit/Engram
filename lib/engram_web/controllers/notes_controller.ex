defmodule EngramWeb.NotesController do
  use EngramWeb, :controller

  alias Engram.Notes

  @max_note_bytes 10 * 1024 * 1024

  def upsert(conn, params) do
    content = params["content"] || params[:content] || ""

    if byte_size(content) > @max_note_bytes do
      conn |> put_status(413) |> json(%{error: "note exceeds maximum size of 10MB"})
    else
      user = conn.assigns.current_user

      case Notes.upsert_note(user, params) do
        {:ok, note} ->
          json(conn, %{note: note_json(note)})

        {:error, changeset} ->
          conn
          |> put_status(422)
          |> json(%{errors: format_errors(changeset)})
      end
    end
  end

  def show(conn, %{"path" => path_parts}) do
    user = conn.assigns.current_user
    path = Enum.join(List.wrap(path_parts), "/")

    case Notes.get_note(user, path) do
      {:ok, note} -> json(conn, note_json(note))
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  def rename(conn, %{"old_path" => old_path, "new_path" => new_path}) do
    user = conn.assigns.current_user

    case Notes.rename_note(user, old_path, new_path) do
      {:ok, note} -> json(conn, %{note: note_json(note)})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  def delete(conn, %{"path" => path_parts}) do
    user = conn.assigns.current_user
    path = Enum.join(List.wrap(path_parts), "/")
    Notes.delete_note(user, path)
    json(conn, %{deleted: true})
  end

  def changes(conn, %{"since" => since_str}) do
    user = conn.assigns.current_user

    case DateTime.from_iso8601(since_str) do
      {:ok, since, _} ->
        {:ok, changes} = Notes.list_changes(user, since)

        json(conn, %{
          changes: Enum.map(changes, &change_json/1),
          server_time: DateTime.utc_now() |> DateTime.to_iso8601()
        })

      {:error, _} ->
        conn |> put_status(400) |> json(%{error: "invalid since timestamp"})
    end
  end

  def changes(conn, _params) do
    conn |> put_status(400) |> json(%{error: "missing required param: since"})
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp note_json(note) do
    %{
      path: note.path,
      title: note.title,
      folder: note.folder || "",
      tags: note.tags || [],
      version: note.version,
      content: note.content,
      mtime: note.mtime,
      updated_at: note.updated_at
    }
  end

  defp change_json(change) do
    %{
      path: change.path,
      title: change.title,
      folder: change.folder || "",
      tags: change.tags || [],
      version: change.version,
      mtime: change.mtime,
      content: change.content,
      deleted: change.deleted,
      updated_at: change.updated_at
    }
  end

  defp format_errors(changeset), do: EngramWeb.format_errors(changeset)
end
