defmodule Engram.Notes do
  @moduledoc """
  Notes context — CRUD for notes, folders, and tags.
  All operations are tenant-scoped via Repo.with_tenant/2.
  """

  import Ecto.Query

  alias Engram.Repo
  alias Engram.Notes.{Note, Helpers, PathSanitizer}

  @doc """
  Creates or updates a note. Sanitizes path, extracts metadata, computes content_hash.
  Returns {:ok, note} or {:error, changeset}.
  """
  @spec upsert_note(map(), map()) :: {:ok, Note.t()} | {:error, Ecto.Changeset.t()}
  def upsert_note(user, attrs) do
    path = attrs["path"] || attrs[:path]
    content = attrs["content"] || attrs[:content] || ""
    mtime = attrs["mtime"] || attrs[:mtime]

    with {:ok, path} <- validate_path(path) do
      sanitized_path = PathSanitizer.sanitize(path)
      title = Helpers.extract_title(content, sanitized_path)
      folder = Helpers.extract_folder(sanitized_path)
      tags = Helpers.extract_tags(content)
      hash = content_hash(content)

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      attrs = %{
        path: sanitized_path,
        content: content,
        title: title,
        folder: folder,
        tags: tags,
        content_hash: hash,
        mtime: mtime,
        user_id: user.id,
        inserted_at: now,
        updated_at: now
      }

      changeset = Note.changeset(%Note{}, attrs)

      Repo.with_tenant(user.id, fn ->
        case Repo.get_by(Note, user_id: user.id, path: sanitized_path) do
          nil ->
            Repo.insert!(changeset)

          existing ->
            existing
            |> Note.changeset(Map.put(attrs, :version, existing.version + 1))
            |> Repo.update!()
        end
      end)
      |> case do
        {:ok, note} -> {:ok, note}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Gets a note by path for a user. Returns {:ok, note} or {:error, :not_found}.
  """
  @spec get_note(map(), String.t()) :: {:ok, Note.t()} | {:error, :not_found}
  def get_note(user, path) do
    result =
      Repo.with_tenant(user.id, fn ->
        Repo.one(
          from(n in Note,
            where: n.user_id == ^user.id and n.path == ^path and is_nil(n.deleted_at)
          )
        )
      end)

    case result do
      {:ok, nil} -> {:error, :not_found}
      {:ok, note} -> {:ok, note}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Soft-deletes a note. Idempotent — returns :ok even if note doesn't exist.
  """
  @spec delete_note(map(), String.t()) :: :ok
  def delete_note(user, path) do
    Repo.with_tenant(user.id, fn ->
      from(n in Note,
        where: n.user_id == ^user.id and n.path == ^path and is_nil(n.deleted_at)
      )
      |> Repo.update_all(set: [deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)])
    end)

    :ok
  end

  @doc """
  Returns notes changed (upserted or deleted) since the given datetime.
  Deleted notes are included with deleted: true.
  """
  @spec list_changes(map(), DateTime.t()) :: {:ok, [map()]}
  def list_changes(user, since) do
    {:ok, notes} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(
          from(n in Note,
            where: n.user_id == ^user.id and n.updated_at > ^since,
            order_by: [asc: n.updated_at]
          )
        )
      end)

    changes =
      Enum.map(notes, fn note ->
        %{
          path: note.path,
          title: note.title,
          folder: note.folder,
          tags: note.tags,
          version: note.version,
          mtime: note.mtime,
          deleted: not is_nil(note.deleted_at),
          updated_at: note.updated_at
        }
      end)

    {:ok, changes}
  end

  @doc """
  Returns unique tags across all non-deleted notes for a user.
  """
  @spec list_tags(map()) :: {:ok, [String.t()]}
  def list_tags(user) do
    {:ok, rows} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(
          from(n in Note,
            where: n.user_id == ^user.id and is_nil(n.deleted_at) and n.tags != ^[],
            select: n.tags
          )
        )
      end)

    tags =
      rows
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.sort()

    {:ok, tags}
  end

  @doc """
  Returns unique non-empty folder paths for a user's notes.
  """
  @spec list_folders(map()) :: {:ok, [String.t()]}
  def list_folders(user) do
    {:ok, folders} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(
          from(n in Note,
            where: n.user_id == ^user.id and is_nil(n.deleted_at) and n.folder != "" and not is_nil(n.folder),
            select: n.folder,
            distinct: true,
            order_by: n.folder
          )
        )
      end)

    {:ok, folders}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp validate_path(nil), do: {:error, Note.changeset(%Note{}, %{}) |> Ecto.Changeset.add_error(:path, "can't be blank")}
  defp validate_path(""), do: {:error, Note.changeset(%Note{}, %{}) |> Ecto.Changeset.add_error(:path, "can't be blank")}
  defp validate_path(path), do: {:ok, path}

  defp content_hash(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end
end
