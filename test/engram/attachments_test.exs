defmodule Engram.AttachmentsTest do
  use Engram.DataCase, async: false

  import Mox

  alias Engram.Attachments
  alias Engram.Attachments.Attachment

  @path "photos/test.png"

  setup :verify_on_exit!

  setup do
    prev = Application.get_env(:engram, :storage)
    Application.put_env(:engram, :storage, Engram.MockStorage)
    on_exit(fn -> Application.put_env(:engram, :storage, prev) end)

    user = insert(:user)
    vault = insert(:vault, user: user)
    storage_key = "#{user.id}/#{vault.id}/#{@path}"
    %{user: user, vault: vault, storage_key: storage_key}
  end

  describe "get_attachment/3 with S3 storage (content nil)" do
    test "fetches binary from storage backend when content is nil", %{user: user, vault: vault, storage_key: storage_key} do
      # Insert an attachment row with content: nil and a storage_key
      {:ok, _att} =
        Repo.with_tenant(user.id, fn ->
          %Attachment{}
          |> Attachment.changeset(%{
            path: @path,
            content: nil,
            content_hash: "abc123",
            mime_type: "image/png",
            size_bytes: 42,
            user_id: user.id,
            vault_id: vault.id,
            storage_key: storage_key
          })
          |> Repo.insert()
        end)

      expect(Engram.MockStorage, :get, fn _key ->
        {:ok, "binary content"}
      end)

      assert {:ok, %Attachment{content: "binary content"}} =
               Attachments.get_attachment(user, vault, @path)
    end

    test "returns storage error when blob is missing for live row", %{user: user, vault: vault, storage_key: storage_key} do
      {:ok, _att} =
        Repo.with_tenant(user.id, fn ->
          %Attachment{}
          |> Attachment.changeset(%{
            path: @path,
            content: nil,
            content_hash: "abc123",
            mime_type: "image/png",
            size_bytes: 42,
            user_id: user.id,
            vault_id: vault.id,
            storage_key: storage_key
          })
          |> Repo.insert()
        end)

      expect(Engram.MockStorage, :get, fn _key ->
        {:error, :not_found}
      end)

      assert {:error, {:storage, :blob_missing}} = Attachments.get_attachment(user, vault, @path)
    end
  end
end
