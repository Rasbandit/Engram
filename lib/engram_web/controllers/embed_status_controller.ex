defmodule EngramWeb.EmbedStatusController do
  use EngramWeb, :controller

  import Ecto.Query

  alias Engram.Notes.Note
  alias Engram.Repo

  def index(conn, _params) do
    user = conn.assigns.current_user

    stats =
      from(n in Note,
        where: n.user_id == ^user.id and is_nil(n.deleted_at),
        select: %{
          total: count(n.id),
          indexed: count(fragment("CASE WHEN ? = ? THEN 1 END", n.embed_hash, n.content_hash)),
          pending:
            count(
              fragment(
                "CASE WHEN ? IS NULL OR ? != ? THEN 1 END",
                n.embed_hash,
                n.embed_hash,
                n.content_hash
              )
            )
        }
      )
      |> Repo.one!(skip_tenant_check: true)

    json(conn, stats)
  end
end
