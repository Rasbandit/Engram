defmodule Engram.Crypto.UserDekRotation do
  @moduledoc """
  T3.7 — per-user DEK rotation orchestrator. Generates a new DEK for the
  target user, rewraps every ciphertext column on every owned row
  (notes / vaults / attachments / Qdrant payloads) under the new key,
  then atomically flips `users.encrypted_dek`.

  The user is locked (read + write) for the duration via
  `Engram.Crypto.RotationLock`; clients receive HTTP 503 with
  `Retry-After: 60` until the rotation completes.

  ## Idempotence

  Unlike `MasterRotation` (which is idempotent within a master key generation),
  this orchestrator generates a **fresh DEK on every call**. There is no
  "already at target" short-circuit. Operators should not re-run unnecessarily.
  The rotation lock prevents concurrent calls; a stale lock (> 10 min) is taken
  over automatically.

  ## Per-row dek_version semantics

  Per-row `dek_version` is the **AAD schema version** (1 = legacy empty-AAD,
  2 = AAD-bound per T3.6). It is NOT a DEK generation counter. The sweep does
  not filter rows by `dek_version < target`; instead it iterates ALL rows for
  the user and uses decrypt-as-discriminator to determine whether each row is
  under the old or new DEK (the latter meaning a prior crashed run already
  re-encrypted it).

  See `docs/encryption-tier-3-audit.md` § Phase T3.7.
  """

  import Ecto.Query, only: [from: 2]

  alias Engram.Accounts.User
  alias Engram.Crypto
  alias Engram.Crypto.{DekCache, Envelope, RotationLock}
  alias Engram.Crypto.KeyProvider.Resolver
  alias Engram.Repo

  require Logger

  @batch_size 200

  @type rotate_result :: :ok | {:error, term()}

  @spec rotate_user(integer() | User.t()) :: rotate_result()
  def rotate_user(user_or_id) do
    user_id =
      case user_or_id do
        %User{id: id} -> id
        id when is_integer(id) -> id
      end

    started_at = System.monotonic_time()
    result = do_rotate(user_id)
    duration_us = duration_us_since(started_at)
    emit_telemetry(user_id, result, duration_us)
    result
  end

  defp do_rotate(user_id) do
    with {:ok, user} <- load_user(user_id),
         {:ok, _locked_at} <- RotationLock.acquire(user_id) do
      new_dek_version = (user.dek_version || 1) + 1

      try do
        run_phases(user, new_dek_version)
      rescue
        e ->
          Logger.error(
            "T3.7 rotate_user crashed user_id=#{user_id} new_dek_version=#{new_dek_version} " <>
              "kind=#{inspect(e.__struct__)} message=#{Exception.message(e)}",
            category: :crypto_rotation
          )

          # Lock intentionally NOT released — operator must investigate
          # before retry. Re-raise so caller sees the failure.
          reraise e, __STACKTRACE__
      end
    else
      {:error, _} = err -> err
    end
  end

  defp load_user(user_id) do
    case Repo.one(from(u in User, where: u.id == ^user_id, select: u), skip_tenant_check: true) do
      nil -> {:error, :not_found}
      %User{} = u -> {:ok, u}
    end
  end

  defp run_phases(%User{} = user, new_dek_version) do
    user_id = user.id

    with {:ok, old_dek} <- Crypto.get_dek(user),
         provider = Resolver.provider_for(user_id),
         {:ok, new_wrapped, new_dek} <-
           provider.rotate_dek(user.encrypted_dek, %{user_id: user_id}),
         new_filter_key = Crypto.dek_filter_key_from_bytes(new_dek),
         :ok <- sweep_notes(user, old_dek, new_dek, new_filter_key, new_dek_version),
         :ok <- sweep_vaults(user, old_dek, new_dek, new_filter_key, new_dek_version),
         :ok <- sweep_attachments(user, old_dek, new_dek, new_filter_key, new_dek_version),
         :ok <- final_flip(user, new_dek_version, new_wrapped) do
      :ok
    else
      {:error, _} = err -> err
    end
  end

  # ---------------------------------------------------------------------------
  # Notes sweep
  # ---------------------------------------------------------------------------

  defp sweep_notes(%User{id: user_id}, old_dek, new_dek, new_filter_key, new_dek_version) do
    sweep_table_loop(
      user_id,
      Engram.Notes.Note,
      0,
      fn batch_ids ->
        Repo.transaction(fn ->
          notes =
            from(n in Engram.Notes.Note,
              where: n.id in ^batch_ids,
              lock: "FOR UPDATE"
            )
            |> Repo.all(skip_tenant_check: true)

          Enum.each(notes, fn note ->
            updates = rewrap_note_columns(note, old_dek, new_dek, new_filter_key, new_dek_version)

            if updates != [] do
              {1, _} =
                from(n in Engram.Notes.Note, where: n.id == ^note.id)
                |> Repo.update_all(
                  [set: updates ++ [dek_version: new_dek_version]],
                  skip_tenant_check: true
                )
            end
          end)
        end)
        |> case do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end
    )
  end

  # ---------------------------------------------------------------------------
  # Vaults sweep
  # ---------------------------------------------------------------------------

  defp sweep_vaults(%User{id: user_id}, old_dek, new_dek, new_filter_key, new_dek_version) do
    sweep_table_loop(
      user_id,
      Engram.Vaults.Vault,
      0,
      fn batch_ids ->
        Repo.transaction(fn ->
          vaults =
            from(v in Engram.Vaults.Vault,
              where: v.id in ^batch_ids,
              lock: "FOR UPDATE"
            )
            |> Repo.all(skip_tenant_check: true)

          Enum.each(vaults, fn vault ->
            updates = rewrap_vault_columns(vault, old_dek, new_dek, new_filter_key, new_dek_version)

            if updates != [] do
              {1, _} =
                from(v in Engram.Vaults.Vault, where: v.id == ^vault.id)
                |> Repo.update_all(
                  [set: updates ++ [dek_version: new_dek_version]],
                  skip_tenant_check: true
                )
            end
          end)
        end)
        |> case do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end
    )
  end

  defp rewrap_vault_columns(%Engram.Vaults.Vault{} = vault, old_dek, new_dek, new_filter_key, new_dek_version) do
    [
      {:name, :name_ciphertext, :name_nonce, :name_hmac}
    ]
    |> Enum.flat_map(fn {column, ct_field, nonce_field, hmac_key} ->
      ct = Map.get(vault, ct_field)
      nonce = Map.get(vault, nonce_field)

      if is_nil(ct) or is_nil(nonce) do
        []
      else
        old_aad = old_aad_for(:vaults, column, vault)
        new_aad = Crypto.aad_for_row(:vaults, column, vault.id)

        case Envelope.decrypt(ct, nonce, old_dek, old_aad) do
          {:ok, plaintext} ->
            # Row was under old DEK — re-encrypt with new DEK
            {new_ct, new_nonce} = Envelope.encrypt(plaintext, new_dek, new_aad)

            [
              {ct_field, new_ct},
              {nonce_field, new_nonce},
              {hmac_key, Crypto.hmac_field(new_filter_key, plaintext)}
            ]

          :error ->
            # Try new DEK — row may already be rotated from a prior crashed run
            case Envelope.decrypt(ct, nonce, new_dek, new_aad) do
              {:ok, _plaintext} ->
                # Already rotated under this run's new_dek — skip
                []

              :error ->
                raise "T3.7 sweep_vaults: decrypt failed under both old and new DEK " <>
                        "for vault id=#{vault.id} column=#{column} new_dek_version=#{new_dek_version}"
            end
        end
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Attachments sweep (two-phase commit per blob)
  # ---------------------------------------------------------------------------
  #
  # Content ciphertext lives in S3, not in the DB — so we cannot do a simple
  # batch UPDATE like notes/vaults. Each attachment requires:
  #   Txn 1: mark dek_version_pending = new_dek_version  (crash-resume marker)
  #   S3 op: GET old ciphertext → decrypt(old_dek) → encrypt(new_dek) → PUT
  #   Txn 2: dek_version = new_dek_version, dek_version_pending = nil,
  #           rewrap path_ciphertext/path_nonce + recompute path_hmac
  #
  # The cursor query picks up rows where either dek_version < new_dek_version OR
  # dek_version_pending == new_dek_version so a crash after Txn 1 is re-tried.
  # Since we now iterate ALL rows (no dek_version filter on the cursor), rows
  # already rotated (dek_version == new_dek_version) are naturally skipped by
  # the decrypt-as-discriminator logic in recrypt_blob.

  defp sweep_attachments(%User{id: user_id}, old_dek, new_dek, new_filter_key, new_dek_version) do
    sweep_attachment_loop(user_id, new_dek_version, old_dek, new_dek, new_filter_key, 0)
  end

  defp sweep_attachment_loop(user_id, new_dek_version, old_dek, new_dek, new_filter_key, last_id) do
    ids =
      from(a in Engram.Attachments.Attachment,
        where: a.user_id == ^user_id and a.id > ^last_id,
        where: is_nil(a.deleted_at),
        order_by: a.id,
        limit: ^@batch_size,
        select: a.id
      )
      |> Repo.all(skip_tenant_check: true)

    case ids do
      [] ->
        :ok

      _ ->
        result =
          Enum.reduce_while(ids, :ok, fn id, :ok ->
            case rotate_one_attachment(id, new_dek_version, old_dek, new_dek, new_filter_key) do
              :ok -> {:cont, :ok}
              {:error, _} = err -> {:halt, err}
            end
          end)

        case result do
          :ok ->
            sweep_attachment_loop(
              user_id,
              new_dek_version,
              old_dek,
              new_dek,
              new_filter_key,
              List.last(ids)
            )

          {:error, _} = err ->
            err
        end
    end
  end

  defp rotate_one_attachment(att_id, new_dek_version, old_dek, new_dek, new_filter_key) do
    with {:ok, _} <- mark_pending(att_id, new_dek_version),
         {:ok, attachment, recrypt_result} <- recrypt_blob(att_id, old_dek, new_dek, new_dek_version),
         :ok <- finalize_attachment(attachment, new_dek_version, old_dek, new_dek, new_filter_key, recrypt_result) do
      :ok
    end
  end

  defp mark_pending(att_id, new_dek_version) do
    Repo.transaction(fn ->
      {1, _} =
        from(a in Engram.Attachments.Attachment, where: a.id == ^att_id)
        |> Repo.update_all([set: [dek_version_pending: new_dek_version]], skip_tenant_check: true)

      :ok
    end)
    |> case do
      {:ok, :ok} -> {:ok, :ok}
      {:error, reason} -> {:error, reason}
    end
  end

  # Returns {:ok, attachment, {:rotated, new_nonce}} when S3 PUT succeeded (blob now under new DEK)
  # Returns {:ok, attachment, :already_rotated} when blob is already under new DEK (prior crashed run)
  defp recrypt_blob(att_id, old_dek, new_dek, new_dek_version) do
    attachment =
      Repo.one!(
        from(a in Engram.Attachments.Attachment, where: a.id == ^att_id),
        skip_tenant_check: true
      )

    {:ok, ct} = Engram.Storage.adapter().get(attachment.storage_key)

    old_aad = old_aad_for(:attachments, :content, attachment)
    new_aad = Crypto.aad_for_row(:attachments, :content, attachment.id)

    case Envelope.decrypt(ct, attachment.content_nonce, old_dek, old_aad) do
      {:ok, plaintext} ->
        # Row was under old DEK — re-encrypt with new DEK and PUT to S3
        {new_ct, new_nonce} = Envelope.encrypt(plaintext, new_dek, new_aad)

        case Engram.Storage.adapter().put(attachment.storage_key, new_ct,
               content_type: attachment.mime_type
             ) do
          :ok -> {:ok, attachment, {:rotated, new_nonce}}
          {:error, _} = err -> err
        end

      :error ->
        # Try new DEK — S3 blob may already be rotated from a prior crashed run
        case Envelope.decrypt(ct, attachment.content_nonce, new_dek, new_aad) do
          {:ok, _plaintext} ->
            # Already rotated — skip the S3 PUT, just finalize the DB row
            {:ok, attachment, :already_rotated}

          :error ->
            raise "T3.7 sweep_attachments: S3 blob decrypt failed under both old and new DEK " <>
                    "for att id=#{att_id} new_dek_version=#{new_dek_version}"
        end
    end
  end

  defp finalize_attachment(
         %Engram.Attachments.Attachment{} = attachment,
         new_dek_version,
         old_dek,
         new_dek,
         new_filter_key,
         recrypt_result
       ) do
    Repo.transaction(fn ->
      meta_updates =
        rewrap_attachment_metadata_columns(
          attachment,
          old_dek,
          new_dek,
          new_filter_key,
          new_dek_version
        )

      nonce_update =
        case recrypt_result do
          {:rotated, new_content_nonce} -> [content_nonce: new_content_nonce]
          :already_rotated -> []
        end

      {1, _} =
        from(a in Engram.Attachments.Attachment, where: a.id == ^attachment.id)
        |> Repo.update_all(
          [
            set:
              meta_updates ++
                nonce_update ++
                [
                  dek_version: new_dek_version,
                  dek_version_pending: nil
                ]
          ],
          skip_tenant_check: true
        )

      :ok
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp rewrap_attachment_metadata_columns(
         %Engram.Attachments.Attachment{} = att,
         old_dek,
         new_dek,
         new_filter_key,
         new_dek_version
       ) do
    [{:path, :path_ciphertext, :path_nonce, :path_hmac}]
    |> Enum.flat_map(fn {column, ct_field, nonce_field, hmac_field_key} ->
      ct = Map.get(att, ct_field)
      nonce = Map.get(att, nonce_field)

      if is_nil(ct) or is_nil(nonce) do
        []
      else
        old_aad = old_aad_for(:attachments, column, att)
        new_aad = Crypto.aad_for_row(:attachments, column, att.id)

        case Envelope.decrypt(ct, nonce, old_dek, old_aad) do
          {:ok, plaintext} ->
            {new_ct, new_nonce} = Envelope.encrypt(plaintext, new_dek, new_aad)

            [
              {ct_field, new_ct},
              {nonce_field, new_nonce},
              {hmac_field_key, Crypto.hmac_field(new_filter_key, plaintext)}
            ]

          :error ->
            # Try new DEK — metadata may already be rotated from a prior crashed run
            case Envelope.decrypt(ct, nonce, new_dek, new_aad) do
              {:ok, _plaintext} ->
                # Already rotated — skip
                []

              :error ->
                raise "T3.7 sweep_attachments: metadata decrypt failed under both old and new DEK " <>
                        "for att id=#{att.id} column=#{column} new_dek_version=#{new_dek_version}"
            end
        end
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Generic cursor-based sweep loop (notes + vaults)
  # ---------------------------------------------------------------------------

  defp sweep_table_loop(user_id, schema, last_id, fun) do
    ids = fetch_batch_ids(user_id, schema, last_id)

    case ids do
      [] ->
        :ok

      _ ->
        case fun.(ids) do
          :ok -> sweep_table_loop(user_id, schema, List.last(ids), fun)
          {:error, _} = err -> err
        end
    end
  end

  # Notes are scoped via vault.user_id AND directly via user_id; use user_id directly.
  defp fetch_batch_ids(user_id, Engram.Notes.Note, last_id) do
    from(n in Engram.Notes.Note,
      where: n.user_id == ^user_id,
      where: n.id > ^last_id,
      order_by: n.id,
      limit: ^@batch_size,
      select: n.id
    )
    |> Repo.all(skip_tenant_check: true)
  end

  # Default fallback for schemas with a direct user_id column.
  defp fetch_batch_ids(user_id, schema, last_id) do
    from(r in schema,
      where: r.user_id == ^user_id,
      where: r.id > ^last_id,
      order_by: r.id,
      limit: ^@batch_size,
      select: r.id
    )
    |> Repo.all(skip_tenant_check: true)
  end

  # Re-encrypt all ciphertext column pairs under the new DEK and recompute
  # HMAC-indexed fields from the decrypted plaintext using the new filter key.
  # Uses decrypt-as-discriminator: try old DEK first; if that fails, try new DEK
  # (handles rows already rotated by a prior crashed run); if both fail, raise.
  defp rewrap_note_columns(%Engram.Notes.Note{} = note, old_dek, new_dek, new_filter_key, new_dek_version) do
    base_columns = [
      {:content, :content_ciphertext, :content_nonce, nil},
      {:title, :title_ciphertext, :title_nonce, nil},
      {:path, :path_ciphertext, :path_nonce, :path_hmac},
      {:folder, :folder_ciphertext, :folder_nonce, :folder_hmac}
    ]

    base_updates =
      base_columns
      |> Enum.flat_map(fn {column, ct_field, nonce_field, hmac_key} ->
        ct = Map.get(note, ct_field)
        nonce = Map.get(note, nonce_field)

        if is_nil(ct) or is_nil(nonce) do
          []
        else
          old_aad = old_aad_for(:notes, column, note)
          new_aad = Crypto.aad_for_row(:notes, column, note.id)

          case Envelope.decrypt(ct, nonce, old_dek, old_aad) do
            {:ok, plaintext} ->
              # Row was under old DEK — re-encrypt with new DEK
              {new_ct, new_nonce} = Envelope.encrypt(plaintext, new_dek, new_aad)

              ct_updates = [{ct_field, new_ct}, {nonce_field, new_nonce}]

              hmac_updates =
                if hmac_key && is_binary(plaintext) do
                  [{hmac_key, Crypto.hmac_field(new_filter_key, plaintext)}]
                else
                  []
                end

              ct_updates ++ hmac_updates

            :error ->
              # Try new DEK — row may already be rotated from a prior crashed run
              case Envelope.decrypt(ct, nonce, new_dek, new_aad) do
                {:ok, _plaintext} ->
                  # Already rotated under this run's new_dek — skip
                  []

                :error ->
                  raise "T3.7 sweep_notes: decrypt failed under both old and new DEK " <>
                          "for note id=#{note.id} column=#{column} new_dek_version=#{new_dek_version}"
              end
          end
        end
      end)

    tag_updates = rewrap_tags(note, old_dek, new_dek, new_filter_key, new_dek_version)

    # If every column is already rotated (all return []), don't touch the row at all.
    # The caller checks `updates != []` before issuing the UPDATE.
    base_updates ++ tag_updates
  end

  defp rewrap_tags(%Engram.Notes.Note{tags_ciphertext: nil}, _old_dek, _new_dek, _new_filter_key, _new_dek_version),
    do: []

  defp rewrap_tags(%Engram.Notes.Note{} = note, old_dek, new_dek, new_filter_key, new_dek_version) do
    ct = note.tags_ciphertext
    nonce = note.tags_nonce

    if is_nil(ct) or is_nil(nonce) do
      []
    else
      old_aad = old_aad_for(:notes, :tags, note)
      new_aad = Crypto.aad_for_row(:notes, :tags, note.id)

      case Envelope.decrypt(ct, nonce, old_dek, old_aad) do
        {:ok, etf_bin} ->
          tags = :erlang.binary_to_term(etf_bin, [:safe])
          new_etf = :erlang.term_to_binary(tags)
          {new_ct, new_nonce} = Envelope.encrypt(new_etf, new_dek, new_aad)

          tags_hmac =
            case tags do
              ts when is_list(ts) -> Enum.map(ts, &Crypto.hmac_field(new_filter_key, &1))
              _ -> []
            end

          [
            {:tags_ciphertext, new_ct},
            {:tags_nonce, new_nonce},
            {:tags_hmac, tags_hmac}
          ]

        :error ->
          # Try new DEK — tags may already be rotated from a prior crashed run
          case Envelope.decrypt(ct, nonce, new_dek, new_aad) do
            {:ok, _etf_bin} ->
              # Already rotated — skip
              []

            :error ->
              raise "T3.7 sweep_notes: decrypt failed under both old and new DEK " <>
                      "for note id=#{note.id} column=tags new_dek_version=#{new_dek_version}"
          end
      end
    end
  end

  # Derive the correct AAD for an existing encrypted row based on its dek_version.
  # Rows with dek_version < 2 were written with empty AAD (pre-T3.6).
  # The bound 2 mirrors Crypto.@row_version_aad_bound — cannot use a remote
  # function call in a guard, so the value is inlined here.
  @aad_version_bound 2

  defp old_aad_for(table, column, %{dek_version: v} = row) when v >= @aad_version_bound,
    do: Crypto.aad_for_row(table, column, row.id)

  defp old_aad_for(_table, _column, _row), do: <<>>

  defp final_flip(%User{} = user, new_dek_version, new_wrapped) do
    Repo.transaction(fn ->
      {1, _} =
        from(u in User, where: u.id == ^user.id)
        |> Repo.update_all(
          [
            set: [
              encrypted_dek: new_wrapped,
              dek_version: new_dek_version,
              dek_rotation_locked_at: nil
            ]
          ],
          skip_tenant_check: true
        )

      DekCache.invalidate(user.id)
      :ok
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp duration_us_since(started_at) do
    System.convert_time_unit(
      System.monotonic_time() - started_at,
      :native,
      :microsecond
    )
  end

  defp emit_telemetry(user_id, :ok, duration_us) do
    :telemetry.execute(
      [:engram, :crypto, :rotate, :dek],
      %{duration_us: duration_us, count: 1},
      %{user_id: user_id, status: :ok}
    )
  end

  defp emit_telemetry(user_id, {:error, reason}, duration_us) do
    label = classify_reason(reason)

    Logger.error(
      "T3.7 rotate_user failed user_id=#{user_id} reason_label=#{label}",
      category: :crypto_rotation
    )

    :telemetry.execute(
      [:engram, :crypto, :rotate, :dek],
      %{duration_us: duration_us, count: 1},
      %{user_id: user_id, status: :failed, reason_label: label}
    )
  end

  defp classify_reason(:not_found), do: "not_found"
  defp classify_reason(:rotation_in_progress), do: "rotation_in_progress"
  defp classify_reason(:invalid_wrapping), do: "invalid_wrapping"
  defp classify_reason(:malformed_wrapped_blob), do: "malformed_wrapped_blob"
  defp classify_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp classify_reason(%Ecto.Changeset{}), do: "changeset_invalid"

  defp classify_reason(reason) when is_exception(reason),
    do: reason.__struct__ |> Module.split() |> List.last()

  defp classify_reason(_other), do: "other"
end
