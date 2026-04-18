defmodule Engram.Crypto do
  @moduledoc """
  Public API for encryption. Wraps the KeyProvider behaviour and DekCache.

  Lazy DEK provisioning: users get a DEK only when encryption is first needed.
  """

  alias Engram.Accounts
  alias Engram.Accounts.User
  alias Engram.Crypto.{DekCache, Envelope, KeyProvider.Resolver}

  @doc """
  Ensures the user has a wrapped DEK stored. Idempotent — returns the user
  untouched if `encrypted_dek` is already present.
  """
  @spec ensure_user_dek(User.t()) :: {:ok, User.t()} | {:error, term()}
  def ensure_user_dek(%User{encrypted_dek: blob} = user) when is_binary(blob), do: {:ok, user}

  def ensure_user_dek(%User{} = user) do
    provider = Resolver.provider_for(user.id)
    dek = provider.generate_dek()

    with {:ok, wrapped} <- provider.wrap_dek(dek, %{user_id: user.id}),
         {:ok, user} <-
           Accounts.update_user_encryption(user, %{
             encrypted_dek: wrapped,
             dek_version: 1,
             key_provider: Atom.to_string(provider.name())
           }) do
      DekCache.put(user.id, dek)
      {:ok, user}
    end
  end

  @doc """
  Returns the plaintext DEK for a user, unwrapping via the provider if not cached.
  """
  @spec get_dek(User.t()) :: {:ok, <<_::256>>} | {:error, term()}
  def get_dek(%User{encrypted_dek: nil}), do: {:error, :no_dek}

  def get_dek(%User{id: user_id, encrypted_dek: blob}) do
    case DekCache.get(user_id) do
      {:ok, dek} ->
        {:ok, dek}

      :miss ->
        provider = Resolver.provider_for(user_id)

        case provider.unwrap_dek(blob, %{user_id: user_id}) do
          {:ok, dek} ->
            DekCache.put(user_id, dek)
            {:ok, dek}

          {:error, _} = err ->
            err
        end
    end
  end

  @doc """
  If `vault.encrypted`, encrypts `content`, `title`, `tags`; sets plaintext
  fields to nil; adds `_ciphertext` + `_nonce` fields. Otherwise passes through.
  """
  @spec maybe_encrypt_note_fields(map(), User.t(), Engram.Vaults.Vault.t()) ::
          {:ok, map()} | {:error, term()}
  def maybe_encrypt_note_fields(attrs, _user, %Engram.Vaults.Vault{encrypted: false}),
    do: {:ok, attrs}

  def maybe_encrypt_note_fields(attrs, %User{} = user, %Engram.Vaults.Vault{encrypted: true}) do
    with {:ok, user} <- ensure_user_dek(user),
         {:ok, dek} <- get_dek(user) do
      content = Map.get(attrs, :content) || Map.get(attrs, "content") || ""
      title = Map.get(attrs, :title) || Map.get(attrs, "title") || ""
      tags = Map.get(attrs, :tags) || Map.get(attrs, "tags") || []

      {content_ct, content_nonce} = Envelope.encrypt(content, dek)
      {title_ct, title_nonce} = Envelope.encrypt(title, dek)
      {tags_ct, tags_nonce} = Envelope.encrypt(:erlang.term_to_binary(tags), dek)

      {:ok,
       attrs
       |> Map.put(:content, nil)
       |> Map.put(:title, nil)
       |> Map.put(:tags, nil)
       |> Map.put(:content_ciphertext, content_ct)
       |> Map.put(:content_nonce, content_nonce)
       |> Map.put(:title_ciphertext, title_ct)
       |> Map.put(:title_nonce, title_nonce)
       |> Map.put(:tags_ciphertext, tags_ct)
       |> Map.put(:tags_nonce, tags_nonce)}
    end
  end

  @doc """
  If note has ciphertext columns populated, decrypt them into `content`/`title`/`tags`.
  Otherwise return the note unchanged.
  """
  @spec maybe_decrypt_note_fields(Engram.Notes.Note.t(), User.t()) ::
          {:ok, Engram.Notes.Note.t()} | {:error, term()}
  def maybe_decrypt_note_fields(%Engram.Notes.Note{content_ciphertext: nil} = note, _user),
    do: {:ok, note}

  def maybe_decrypt_note_fields(%Engram.Notes.Note{} = note, %User{} = user) do
    with {:ok, dek} <- get_dek(user),
         {:ok, content} <- Envelope.decrypt(note.content_ciphertext, note.content_nonce, dek),
         {:ok, title} <- Envelope.decrypt(note.title_ciphertext, note.title_nonce, dek),
         {:ok, tags_bin} <- Envelope.decrypt(note.tags_ciphertext, note.tags_nonce, dek) do
      tags = :erlang.binary_to_term(tags_bin, [:safe])
      {:ok, %{note | content: content, title: title, tags: tags}}
    else
      :error -> {:error, :decrypt_failed}
      {:error, _} = err -> err
    end
  end
end
