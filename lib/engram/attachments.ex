defmodule Engram.Attachments do
  @moduledoc """
  Attachments context — CRUD for binary file attachments.
  All operations are tenant-scoped via Repo.with_tenant/2.

  Binary storage is delegated to the configured storage adapter
  (Database for BYTEA in Postgres, S3 for MinIO/Tigris).
  """

  import Ecto.Query

  alias Engram.Repo
  alias Engram.Attachments.Attachment
  alias Engram.Storage

  defp storage, do: Application.get_env(:engram, :storage, Storage.Database)

  @doc """
  Upserts an attachment. Decodes base64 content, detects MIME type, computes hash.
  Returns {:ok, attachment} or {:error, reason}.
  """
  def upsert_attachment(user, attrs) do
    path = attrs["path"] || attrs[:path]
    content_b64 = attrs["content_base64"] || attrs[:content_base64]
    mtime = attrs["mtime"] || attrs[:mtime]
    explicit_mime = attrs["mime_type"] || attrs[:mime_type]

    with {:ok, binary} <- decode_base64(content_b64) do
      size = byte_size(binary)

      if size > Attachment.max_attachment_bytes() do
        {:error, :too_large}
      else
        mime = explicit_mime || detect_mime(path)
        hash = :crypto.hash(:md5, binary) |> Base.encode16(case: :lower)
        key = Storage.key(user.id, path)
        backend = storage()

        # For S3 backend, store binary externally first
        if backend != Storage.Database do
          case backend.put(key, binary, content_type: mime) do
            :ok -> :ok
            {:error, reason} -> throw({:storage_error, reason})
          end
        end

        changeset_attrs =
          %{
            path: path,
            content_hash: hash,
            mime_type: mime,
            size_bytes: size,
            mtime: mtime,
            user_id: user.id,
            storage_key: key,
            deleted_at: nil
          }
          |> maybe_include_content(backend, binary)

        Repo.with_tenant(user.id, fn ->
          existing =
            Repo.one(from(a in Attachment, where: a.path == ^path and a.user_id == ^user.id))

          case existing do
            nil ->
              %Attachment{}
              |> Attachment.changeset(changeset_attrs)
              |> Repo.insert()

            att ->
              att
              |> Attachment.changeset(changeset_attrs)
              |> Repo.update()
          end
        end)
        |> unwrap_tenant()
      end
    end
  catch
    {:storage_error, reason} -> {:error, {:storage, reason}}
  end

  @doc """
  Gets an attachment by path. Returns nil for soft-deleted.
  Fetches binary content from the configured storage backend.
  """
  def get_attachment(user, path) do
    result =
      Repo.with_tenant(user.id, fn ->
        Repo.one(
          from(a in Attachment,
            where: a.path == ^path and a.user_id == ^user.id and is_nil(a.deleted_at)
          )
        )
      end)
      |> unwrap_tenant()

    case result do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, %Attachment{content: content} = att} when not is_nil(content) ->
        # Content already in the row (Database adapter)
        {:ok, att}

      {:ok, %Attachment{} = att} ->
        # Content stored externally (S3 adapter) — fetch it
        key = att.storage_key || Storage.key(user.id, path)

        case storage().get(key) do
          {:ok, binary} -> {:ok, %{att | content: binary}}
          {:error, :not_found} -> {:ok, nil}
          {:error, reason} -> {:error, {:storage, reason}}
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Soft-deletes an attachment. Idempotent — returns :ok even if already deleted or nonexistent.
  Also deletes from external storage if using S3 backend.
  """
  def delete_attachment(user, path) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    backend = storage()

    # Delete from external storage (no-op for Database adapter)
    if backend != Storage.Database do
      key = Storage.key(user.id, path)
      backend.delete(key)
    end

    Repo.with_tenant(user.id, fn ->
      from(a in Attachment,
        where: a.path == ^path and a.user_id == ^user.id and is_nil(a.deleted_at)
      )
      |> Repo.update_all(set: [deleted_at: now, updated_at: now])
    end)

    :ok
  end

  @doc """
  Lists attachment changes since a given timestamp. Returns metadata only (no content).
  """
  def list_changes(user, since) do
    Repo.with_tenant(user.id, fn ->
      from(a in Attachment,
        where: a.user_id == ^user.id and a.updated_at > ^since,
        order_by: [asc: a.updated_at],
        select: %{
          path: a.path,
          mime_type: a.mime_type,
          size_bytes: a.size_bytes,
          mtime: a.mtime,
          updated_at: a.updated_at,
          deleted_at: a.deleted_at
        }
      )
      |> Repo.all()
    end)
    |> unwrap_tenant()
  end

  @doc """
  Returns storage usage for a user: total bytes and file count.
  """
  def storage_usage(user) do
    Repo.with_tenant(user.id, fn ->
      from(a in Attachment,
        where: a.user_id == ^user.id and is_nil(a.deleted_at),
        select: %{
          used_bytes: type(coalesce(sum(a.size_bytes), 0), :integer),
          file_count: count(a.id)
        }
      )
      |> Repo.one()
    end)
    |> unwrap_tenant()
  end

  # -- Private helpers --

  defp maybe_include_content(attrs, Storage.Database, binary) do
    Map.put(attrs, :content, binary)
  end

  defp maybe_include_content(attrs, _s3_backend, _binary), do: attrs

  defp decode_base64(nil), do: {:error, :missing_content}

  defp decode_base64(b64) when is_binary(b64) do
    case Base.decode64(b64) do
      {:ok, binary} -> {:ok, binary}
      :error -> {:error, :invalid_base64}
    end
  end

  defp detect_mime(path) do
    case Path.extname(path) |> String.downcase() do
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      ".svg" -> "image/svg+xml"
      ".pdf" -> "application/pdf"
      ".mp3" -> "audio/mpeg"
      ".mp4" -> "video/mp4"
      ".wav" -> "audio/wav"
      ".txt" -> "text/plain"
      ".md" -> "text/markdown"
      ".json" -> "application/json"
      ".css" -> "text/css"
      ".js" -> "application/javascript"
      ".html" -> "text/html"
      ".zip" -> "application/zip"
      ".tar" -> "application/x-tar"
      ".gz" -> "application/gzip"
      _ -> "application/octet-stream"
    end
  end

  defp unwrap_tenant({:ok, {:ok, result}}), do: {:ok, result}
  defp unwrap_tenant({:ok, {:error, _} = err}), do: err
  defp unwrap_tenant({:ok, result}), do: {:ok, result}
  defp unwrap_tenant({:error, _} = err), do: err
end
