defmodule Engram.Attachments do
  @moduledoc """
  Attachments context — CRUD for binary file attachments.
  All operations are tenant-scoped via Repo.with_tenant/2.
  """

  import Ecto.Query

  alias Engram.Repo
  alias Engram.Attachments.Attachment

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

        Repo.with_tenant(user.id, fn ->
          existing =
            Repo.one(
              from(a in Attachment, where: a.path == ^path and a.user_id == ^user.id)
            )

          changeset_attrs = %{
            path: path,
            content: binary,
            content_hash: hash,
            mime_type: mime,
            size_bytes: size,
            mtime: mtime,
            user_id: user.id,
            deleted_at: nil
          }

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
  end

  @doc """
  Gets an attachment by path. Returns nil for soft-deleted.
  """
  def get_attachment(user, path) do
    Repo.with_tenant(user.id, fn ->
      Repo.one(
        from(a in Attachment,
          where: a.path == ^path and a.user_id == ^user.id and is_nil(a.deleted_at)
        )
      )
    end)
    |> unwrap_tenant()
  end

  @doc """
  Soft-deletes an attachment. Idempotent — returns :ok even if already deleted or nonexistent.
  """
  def delete_attachment(user, path) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

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
          used_bytes: coalesce(sum(a.size_bytes), 0),
          file_count: count(a.id)
        }
      )
      |> Repo.one()
    end)
    |> unwrap_tenant()
  end

  # -- Private helpers --

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
