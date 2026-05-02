defmodule Engram.Attachments.Attachment do
  use Ecto.Schema
  import Ecto.Changeset

  @max_attachment_bytes 5 * 1024 * 1024

  schema "attachments" do
    field :path, :string
    # Plaintext bytes are never persisted on the row — they live in the
    # configured S3-compatible adapter (Tigris in prod, MinIO in CI/dev).
    # `content` is a transient virtual field populated by `get_attachment/3`
    # after fetch + decrypt.
    field :content, :binary, virtual: true
    field :content_hash, :string
    field :mime_type, :string
    field :size_bytes, :integer
    field :mtime, :float
    field :storage_key, :string
    field :deleted_at, :utc_datetime
    field :encryption_version, :integer, default: 0
    field :content_nonce, :binary

    belongs_to :user, Engram.Accounts.User
    belongs_to :vault, Engram.Vaults.Vault

    timestamps(type: :utc_datetime, inserted_at: :created_at)
  end

  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [
      :path,
      :content_hash,
      :mime_type,
      :size_bytes,
      :mtime,
      :user_id,
      :vault_id,
      :storage_key,
      :deleted_at,
      :encryption_version,
      :content_nonce
    ])
    |> validate_required([:path, :user_id, :vault_id, :content_hash, :mime_type, :size_bytes])
    |> validate_number(:size_bytes, less_than_or_equal_to: @max_attachment_bytes)
    |> validate_inclusion(:encryption_version, [0, 1])
    |> validate_nonce_consistency()
    |> unique_constraint([:user_id, :vault_id, :path],
      name: :attachments_user_vault_path_active_index
    )
  end

  defp validate_nonce_consistency(changeset) do
    case get_field(changeset, :encryption_version) do
      1 ->
        case get_field(changeset, :content_nonce) do
          nil -> add_error(changeset, :content_nonce, "required when encryption_version=1")
          _ -> changeset
        end

      _ ->
        changeset
    end
  end

  def max_attachment_bytes, do: @max_attachment_bytes
end
