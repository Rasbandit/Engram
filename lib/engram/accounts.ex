defmodule Engram.Accounts do
  @moduledoc """
  Account management: Clerk auth, API keys, JWT.
  """

  import Ecto.Query
  alias Engram.Repo
  alias Engram.Accounts.{User, ApiKey}
  alias Engram.Auth.RefreshToken
  alias Bcrypt

  @api_key_prefix "engram_"

  def get_user!(id), do: Repo.get!(User, id, skip_tenant_check: true)

  def get_user(id), do: Repo.get(User, id, skip_tenant_check: true)

  # ── Clerk Auth ─────────────────────────────────────────────────

  @doc """
  Finds a user by external ID (Clerk sub), or links/creates one.

  Priority: external_id match > email match (link external_id) > create new user.
  """
  def find_or_create_by_external_id(external_id, %{email: email}) do
    case Repo.one(from(u in User, where: u.external_id == ^external_id), skip_tenant_check: true) do
      %User{} = user ->
        {:ok, user}

      nil ->
        case Repo.one(from(u in User, where: u.email == ^email), skip_tenant_check: true) do
          %User{} = user ->
            user
            |> Ecto.Changeset.change(%{external_id: external_id})
            |> Repo.update(skip_tenant_check: true)

          nil ->
            %User{external_id: external_id, email: email}
            |> Repo.insert(skip_tenant_check: true)
        end
    end
  end

  # ── Local Auth ─────────────────────────────────────────────────

  def create_user_with_password(email, password) do
    role = if Repo.aggregate(User, :count) == 0, do: "admin", else: "member"
    external_id = Ecto.UUID.generate()

    %User{
      email: email,
      external_id: external_id,
      password_hash: Bcrypt.hash_pwd_salt(password),
      role: role
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:email)
    |> Repo.insert(skip_tenant_check: true)
  end

  def verify_password(email, password) do
    case Repo.one(from(u in User, where: u.email == ^email), skip_tenant_check: true) do
      %User{password_hash: hash} = user when is_binary(hash) ->
        if Bcrypt.verify_pass(password, hash),
          do: {:ok, user},
          else: {:error, :invalid_credentials}

      %User{password_hash: nil} ->
        Bcrypt.no_user_verify()
        {:error, :invalid_credentials}

      nil ->
        Bcrypt.no_user_verify()
        {:error, :invalid_credentials}
    end
  end

  # ── Refresh Tokens ─────────────────────────────────────────────

  @refresh_token_ttl_days 30

  def create_refresh_token(user, family_id \\ nil) do
    raw_token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    token_hash = hash_refresh_token(raw_token)
    family_id = family_id || Ecto.UUID.generate()

    {:ok, record} =
      %RefreshToken{}
      |> RefreshToken.changeset(%{
        user_id: user.id,
        token_hash: token_hash,
        family_id: family_id,
        expires_at:
          DateTime.add(DateTime.utc_now(), @refresh_token_ttl_days * 24 * 3600, :second)
          |> DateTime.truncate(:second)
      })
      |> Repo.insert(skip_tenant_check: true)

    {raw_token, record}
  end

  def consume_refresh_token(raw_token) do
    token_hash = hash_refresh_token(raw_token)

    case Repo.one(
           from(rt in RefreshToken, where: rt.token_hash == ^token_hash, preload: :user),
           skip_tenant_check: true
         ) do
      nil ->
        {:error, :invalid_token}

      %RefreshToken{revoked_at: revoked} when not is_nil(revoked) ->
        # Reuse of revoked token — compromise detected. Revoke entire family.
        revoke_token_family(token_hash)
        {:error, :token_reused}

      %RefreshToken{expires_at: expires_at} = token ->
        if DateTime.compare(DateTime.utc_now(), expires_at) == :gt do
          {:error, :expired}
        else
          token
          |> Ecto.Changeset.change(%{revoked_at: DateTime.utc_now() |> DateTime.truncate(:second)})
          |> Repo.update(skip_tenant_check: true)

          {new_raw, new_record} = create_refresh_token(token.user, token.family_id)
          {:ok, token.user, new_raw, new_record}
        end
    end
  end

  def revoke_token_family(family_id_or_token_hash) do
    family_id =
      case Repo.one(
             from(rt in RefreshToken,
               where: rt.token_hash == ^family_id_or_token_hash,
               select: rt.family_id
             ),
             skip_tenant_check: true
           ) do
        nil -> family_id_or_token_hash
        fid -> fid
      end

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(rt in RefreshToken,
      where: rt.family_id == ^family_id and is_nil(rt.revoked_at)
    )
    |> Repo.update_all([set: [revoked_at: now]], skip_tenant_check: true)
  end

  defp hash_refresh_token(raw_token) do
    :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)
  end

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
      api_key -> {:ok, api_key.user, api_key}
    end
  end

  def list_api_keys(user) do
    {:ok, keys} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(from(k in ApiKey, where: k.user_id == ^user.id, order_by: [desc: k.created_at]))
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
