defmodule EngramWeb.SyncChannel do
  @moduledoc """
  Per-user WebSocket channel for bidirectional note sync.

  Topic: "sync:{user_id}"
  Auth:  socket.assigns.current_user must match the user_id in the topic.

  Client → Server events: push_note, delete_note, rename_note, pull_changes
  Server → Client broadcasts: note_changed
  """

  use Phoenix.Channel

  alias Engram.Notes
  alias EngramWeb.Presence

  # ---------------------------------------------------------------------------
  # Join
  # ---------------------------------------------------------------------------

  @impl true
  def join("sync:" <> user_id_str, params, socket) do
    current_user = socket.assigns.current_user

    if to_string(current_user.id) == user_id_str do
      send(self(), {:after_join, params})
      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info({:after_join, params}, socket) do
    device_id = Map.get(params, "device_id", "unknown")

    {:ok, _} =
      Presence.track(socket, device_id, %{
        joined_at: DateTime.utc_now() |> DateTime.to_iso8601()
      })

    push(socket, "presence_state", Presence.list(socket))
    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # push_note
  # ---------------------------------------------------------------------------

  @impl true
  def handle_in("push_note", params, socket) do
    user = socket.assigns.current_user

    case Notes.upsert_note(user, params) do
      {:ok, note} ->
        broadcast_from!(socket, "note_changed", %{
          "event_type" => "upsert",
          "path" => note.path,
          "kind" => "note",
          "timestamp" => DateTime.to_iso8601(note.updated_at)
        })

        reply = %{
          "note" => serialize_note(note),
          "indexing" => "queued"
        }

        {:reply, {:ok, reply}, socket}

      {:error, changeset} ->
        {:reply, {:error, %{"reason" => format_errors(changeset)}}, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # delete_note
  # ---------------------------------------------------------------------------

  @impl true
  def handle_in("delete_note", %{"path" => path}, socket) do
    user = socket.assigns.current_user
    :ok = Notes.delete_note(user, path)

    broadcast_from!(socket, "note_changed", %{
      "event_type" => "delete",
      "path" => path,
      "kind" => "note",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    })

    {:reply, {:ok, %{"deleted" => true}}, socket}
  end

  # ---------------------------------------------------------------------------
  # rename_note
  # ---------------------------------------------------------------------------

  @impl true
  def handle_in("rename_note", %{"old_path" => old_path, "new_path" => new_path}, socket) do
    user = socket.assigns.current_user

    case Notes.rename_note(user, old_path, new_path) do
      {:ok, note} ->
        now = DateTime.utc_now() |> DateTime.to_iso8601()

        # Broadcast tombstone for old path + create for new path
        broadcast_from!(socket, "note_changed", %{
          "event_type" => "delete",
          "path" => old_path,
          "kind" => "note",
          "timestamp" => now
        })

        broadcast_from!(socket, "note_changed", %{
          "event_type" => "upsert",
          "path" => note.path,
          "kind" => "note",
          "timestamp" => now
        })

        {:reply, {:ok, %{"note" => serialize_note(note)}}, socket}

      {:error, :not_found} ->
        {:reply, {:error, %{"reason" => "note not found"}}, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # pull_changes
  # ---------------------------------------------------------------------------

  @impl true
  def handle_in("pull_changes", %{"since" => since_str}, socket) do
    user = socket.assigns.current_user

    case DateTime.from_iso8601(since_str) do
      {:ok, since, _} ->
        {:ok, changes} = Notes.list_changes(user, since)

        serialized =
          Enum.map(changes, fn c ->
            %{
              "path" => c.path,
              "title" => c.title,
              "folder" => c.folder,
              "tags" => c.tags,
              "version" => c.version,
              "mtime" => c.mtime,
              "deleted" => c.deleted,
              "updated_at" => DateTime.to_iso8601(c.updated_at)
            }
          end)

        reply = %{
          "changes" => serialized,
          "server_time" => DateTime.utc_now() |> DateTime.to_iso8601()
        }

        {:reply, {:ok, reply}, socket}

      {:error, _} ->
        {:reply, {:error, %{"reason" => "invalid since timestamp"}}, socket}
    end
  end

  def handle_in("pull_changes", _params, socket) do
    {:reply, {:error, %{"reason" => "since is required"}}, socket}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp serialize_note(note) do
    %{
      "path" => note.path,
      "title" => note.title,
      "folder" => note.folder,
      "tags" => note.tags,
      "version" => note.version,
      "content_hash" => note.content_hash,
      "mtime" => note.mtime,
      "updated_at" => DateTime.to_iso8601(note.updated_at)
    }
  end

  defp format_errors(changeset), do: EngramWeb.format_errors(changeset)
end
