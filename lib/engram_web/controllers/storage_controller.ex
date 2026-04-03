defmodule EngramWeb.StorageController do
  use EngramWeb, :controller

  alias Engram.Attachments
  alias Engram.Attachments.Attachment

  @max_storage_bytes 1_073_741_824

  def index(conn, _params) do
    user = conn.assigns.current_user
    {:ok, usage} = Attachments.storage_usage(user)

    json(conn, %{
      used_bytes: usage.used_bytes,
      file_count: usage.file_count,
      max_bytes: @max_storage_bytes,
      max_attachment_bytes: Attachment.max_attachment_bytes()
    })
  end
end
