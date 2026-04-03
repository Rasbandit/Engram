defmodule Engram.Accounts do
  @moduledoc """
  Account management: user registration, authentication, API keys, JWT.
  """

  import Ecto.Query
  alias Engram.Repo
  alias Engram.Accounts.{User, ApiKey}

  @api_key_prefix "engram_"

  # ── User Registration & Auth ────────────────────────────────────

  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert(skip_tenant_check: true)
  end

  def authenticate_user(email, password) do
    user = Repo.one(from(u in User, where: u.email == ^email), skip_tenant_check: true)

    case user do
      nil ->
        Argon2.no_user_verify()
        {:error, :invalid_credentials}

      user ->
        if Argon2.verify_pass(password, user.password_hash) do
          {:ok, user}
        else
          {:error, :invalid_credentials}
        end
    end
  end

  def get_user!(id), do: Repo.get!(User, id, skip_tenant_check: true)

  def get_user(id), do: Repo.get(User, id, skip_tenant_check: true)

  # ── JWT ─────────────────────────────────────────────────────────

  def generate_jwt(user) do
    extra_claims = %{"user_id" => user.id}
    Engram.Token.generate_and_sign!(extra_claims)
  end

  def verify_jwt(token) do
    case Engram.Token.verify_and_validate(token) do
      {:ok, claims} -> {:ok, claims}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── API Keys ────────────────────────────────────────────────────

  def create_api_key(user, name) do
    raw_key = @api_key_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    key_hash = hash_api_key(raw_key)

    result =
      Repo.with_tenant(user.id, fn ->
        %ApiKey{}
        |> ApiKey.changeset(%{key_hash: key_hash, name: name, user_id: user.id})
        |> Repo.insert()
      end)

    case result do
      {:ok, {:ok, api_key}} -> {:ok, raw_key, api_key}
      {:ok, {:error, changeset}} -> {:error, changeset}
    end
  end

  def validate_api_key(raw_key) do
    key_hash = hash_api_key(raw_key)

    case Repo.one(from(k in ApiKey, where: k.key_hash == ^key_hash, preload: :user),
           skip_tenant_check: true
         ) do
      nil -> {:error, :invalid_key}
      api_key -> {:ok, api_key.user}
    end
  end

  def list_api_keys(user) do
    {:ok, keys} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(from(k in ApiKey, where: k.user_id == ^user.id, order_by: [desc: k.inserted_at]))
      end)

    keys
  end

  def revoke_api_key(user, api_key_id) do
    result =
      Repo.with_tenant(user.id, fn ->
        case Repo.get_by(ApiKey, id: api_key_id, user_id: user.id) do
          nil -> {:error, :not_found}
          key -> Repo.delete(key)
        end
      end)

    case result do
      {:ok, {:ok, _}} -> :ok
      {:ok, {:error, :not_found}} -> {:error, :not_found}
      {:ok, {:error, changeset}} -> {:error, changeset}
    end
  end

  defp hash_api_key(raw_key) do
    :crypto.hash(:sha256, raw_key) |> Base.encode16(case: :lower)
  end
end
