defmodule EngramWeb.SyncController do
  use EngramWeb, :controller

  import Ecto.Query

  alias Engram.Repo
  alias Engram.Notes.Note
  alias Engram.Attachments.Attachment

  def manifest(conn, _params) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    {:ok, notes} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(
          from(n in Note,
            where: n.user_id == ^user.id and n.vault_id == ^vault.id and is_nil(n.deleted_at),
            select: %{path: n.path, content_hash: n.content_hash},
            order_by: n.path
          )
        )
      end)

    {:ok, attachments} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(
          from(a in Attachment,
            where: a.user_id == ^user.id and a.vault_id == ^vault.id and is_nil(a.deleted_at),
            select: %{path: a.path, content_hash: a.content_hash},
            order_by: a.path
          )
        )
      end)

    json(conn, %{
      notes: notes,
      attachments: attachments,
      total_notes: length(notes),
      total_attachments: length(attachments)
    })
  end
end
