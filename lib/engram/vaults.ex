defmodule Engram.Vaults do
  @moduledoc """
  Vaults context — CRUD, registration, and default resolution for vaults.
  All write operations are tenant-scoped via Repo.with_tenant/2.
  """

  import Ecto.Query

  alias Engram.Billing
  alias Engram.Repo
  alias Engram.Vaults.Vault

  # ── Create ─────────────────────────────────────────────────────────────────

  @doc """
  Creates a new vault for a user.

  - Enforces billing limit (max_vaults).
  - First vault is automatically set as default.
  - Generates a unique slug from the name.

  Returns {:ok, vault} or {:error, :vault_limit_reached} or {:error, changeset}.
  """
  def create_vault(user, attrs) do
    Repo.with_tenant(user.id, fn ->
      current_count = count_vaults(user.id)

      case Billing.check_limit(user, "max_vaults", current_count) do
        {:error, :limit_reached} ->
          {:error, :vault_limit_reached}

        :ok ->
          is_default = current_count == 0
          name = attrs[:name] || attrs["name"] || ""
          slug = unique_slug(user.id, slugify(name))

          vault_attrs =
            attrs
            |> atomize_keys()
            |> Map.merge(%{slug: slug, user_id: user.id, is_default: is_default})

          %Vault{}
          |> Vault.changeset(vault_attrs)
          |> Repo.insert()
      end
    end)
    |> unwrap_transaction()
  end

  # ── Register (idempotent) ───────────────────────────────────────────────────

  @doc """
  Registers a vault by client_id. Idempotent: returns the existing vault if
  a non-deleted vault with this client_id already exists for the user.

  Returns:
    {:ok, vault, :created}   — new vault was inserted
    {:ok, vault, :existing}  — matched an existing vault
    {:error, :vault_limit_reached}
  """
  def register_vault(user, name, client_id) do
    result =
      Repo.with_tenant(user.id, fn ->
        case find_by_client_id(user.id, client_id) do
          %Vault{} = existing ->
            {:ok, existing, :existing}

          nil ->
            current_count = count_vaults(user.id)

            case Billing.check_limit(user, "max_vaults", current_count) do
              {:error, :limit_reached} ->
                {:error, :vault_limit_reached}

              :ok ->
                is_default = current_count == 0
                slug = unique_slug(user.id, slugify(name))

                attrs = %{
                  name: name,
                  client_id: client_id,
                  slug: slug,
                  user_id: user.id,
                  is_default: is_default
                }

                case Repo.insert(Vault.changeset(%Vault{}, attrs)) do
                  {:ok, vault} -> {:ok, vault, :created}
                  {:error, cs} -> {:error, cs}
                end
            end
        end
      end)

    unwrap_register_transaction(result)
  end

  # ── List ────────────────────────────────────────────────────────────────────

  @doc """
  Returns all non-deleted vaults for a user, ordered by inserted_at ascending.
  """
  def list_vaults(user) do
    {:ok, vaults} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(
          from v in Vault,
            where: v.user_id == ^user.id and is_nil(v.deleted_at),
            order_by: [asc: fragment("created_at")]
        )
      end)

    vaults
  end

  # ── Get ─────────────────────────────────────────────────────────────────────

  @doc """
  Returns {:ok, vault} for a non-deleted vault owned by the user,
  or {:error, :not_found}.
  """
  def get_vault(user, vault_id) do
    result =
      Repo.with_tenant(user.id, fn ->
        Repo.one(
          from v in Vault,
            where: v.user_id == ^user.id and v.id == ^vault_id and is_nil(v.deleted_at)
        )
      end)

    case result do
      {:ok, nil} -> {:error, :not_found}
      {:ok, vault} -> {:ok, vault}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Returns {:ok, vault} for the user's default vault, or {:error, :no_default_vault}.
  """
  def get_default_vault(user) do
    result =
      Repo.with_tenant(user.id, fn ->
        Repo.one(
          from v in Vault,
            where: v.user_id == ^user.id and v.is_default == true and is_nil(v.deleted_at)
        )
      end)

    case result do
      {:ok, nil} -> {:error, :no_default_vault}
      {:ok, vault} -> {:ok, vault}
      _ -> {:error, :no_default_vault}
    end
  end

  # ── Update ──────────────────────────────────────────────────────────────────

  @doc """
  Updates a vault's attributes.

  - If `is_default: true` is set, clears is_default on all other vaults first.
  - If `name` changes, regenerates the slug.

  Returns {:ok, vault} or {:error, :not_found} or {:error, changeset}.
  """
  def update_vault(user, vault_id, attrs) do
    Repo.with_tenant(user.id, fn ->
      case fetch_active(user.id, vault_id) do
        nil ->
          {:error, :not_found}

        vault ->
          attrs = attrs |> atomize_keys() |> then(&maybe_regenerate_slug(user.id, vault, &1))

          if Map.get(attrs, :is_default) == true do
            clear_defaults(user.id, vault_id)
          end

          vault
          |> Vault.changeset(attrs)
          |> Repo.update()
      end
    end)
    |> unwrap_transaction()
  end

  # ── Delete (soft) ───────────────────────────────────────────────────────────

  @doc """
  Soft-deletes a vault by setting deleted_at and clearing is_default.

  If the deleted vault was the default, promotes the next oldest non-deleted vault.

  Note: background cleanup (Qdrant vectors, S3 attachments) is handled by
  a CleanupVault worker — TODO: enqueue CleanupVault.new(%{vault_id: vault.id}) once Task 14 is done.

  Returns {:ok, vault} or {:error, :not_found}.
  """
  def delete_vault(user, vault_id) do
    Repo.with_tenant(user.id, fn ->
      case fetch_active(user.id, vault_id) do
        nil ->
          {:error, :not_found}

        vault ->
          was_default = vault.is_default

          result =
            vault
            |> Vault.changeset(%{deleted_at: DateTime.utc_now() |> DateTime.truncate(:second), is_default: false})
            |> Repo.update()

          if was_default do
            promote_next_default(user.id)
          end

          result
      end
    end)
    |> unwrap_transaction()
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  defp count_vaults(user_id) do
    Repo.one!(
      from v in Vault,
        where: v.user_id == ^user_id and is_nil(v.deleted_at),
        select: count(v.id)
    )
  end

  defp fetch_active(user_id, vault_id) do
    Repo.one(
      from v in Vault,
        where: v.user_id == ^user_id and v.id == ^vault_id and is_nil(v.deleted_at)
    )
  end

  defp find_by_client_id(user_id, client_id) do
    Repo.one(
      from v in Vault,
        where: v.user_id == ^user_id and v.client_id == ^client_id and is_nil(v.deleted_at)
    )
  end

  defp clear_defaults(user_id, except_vault_id) do
    Repo.update_all(
      from(v in Vault,
        where: v.user_id == ^user_id and v.id != ^except_vault_id and v.is_default == true
      ),
      set: [is_default: false]
    )
  end

  defp promote_next_default(user_id) do
    next =
      Repo.one(
        from v in Vault,
          where: v.user_id == ^user_id and is_nil(v.deleted_at),
          order_by: [asc: fragment("created_at")],
          limit: 1
      )

    if next do
      Repo.update_all(
        from(v in Vault, where: v.id == ^next.id),
        set: [is_default: true]
      )
    end
  end

  defp maybe_regenerate_slug(user_id, vault, attrs) do
    new_name = Map.get(attrs, :name) || Map.get(attrs, "name")

    if new_name && new_name != vault.name do
      slug = unique_slug(user_id, slugify(new_name), vault.id)
      Map.put(attrs, :slug, slug)
    else
      attrs
    end
  end

  @doc false
  def slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^\w\s-]/, "")
    |> String.replace(~r/[\s_]+/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "vault"
      slug -> slug
    end
  end

  # Finds a slug that doesn't collide with any existing non-deleted vault for this user.
  # Optionally excludes `except_id` (for renames — the vault itself doesn't count).
  defp unique_slug(user_id, base_slug, except_id \\ nil) do
    query =
      from v in Vault,
        where: v.user_id == ^user_id and is_nil(v.deleted_at),
        select: v.slug

    query =
      if except_id do
        from v in query, where: v.id != ^except_id
      else
        query
      end

    existing = Repo.all(query)

    if base_slug not in existing do
      base_slug
    else
      Enum.find_value(2..1000, fn n ->
        candidate = "#{base_slug}-#{n}"
        if candidate not in existing, do: candidate
      end)
    end
  end

  # with_tenant wraps the result in {:ok, value} — unwrap it cleanly.
  defp unwrap_transaction({:ok, {:ok, vault}}), do: {:ok, vault}
  defp unwrap_transaction({:ok, {:error, reason}}), do: {:error, reason}
  defp unwrap_transaction({:error, _} = err), do: err

  defp unwrap_register_transaction({:ok, {:ok, vault, tag}}), do: {:ok, vault, tag}
  defp unwrap_register_transaction({:ok, {:error, reason}}), do: {:error, reason}
  defp unwrap_register_transaction({:error, _} = err), do: err

  # Converts string-keyed maps to atom-keyed so atom merges don't produce mixed maps.
  defp atomize_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  end
end
