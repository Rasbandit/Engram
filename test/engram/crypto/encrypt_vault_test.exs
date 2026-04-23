defmodule Engram.Crypto.EncryptVaultTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Crypto
  alias Engram.Vaults.Vault
  alias Engram.Workers.EncryptVault
  alias Engram.Repo

  setup do
    user = insert(:user)
    vault = insert(:vault, user: user, encrypted: false, encryption_status: "none")
    %{user: user, vault: vault}
  end

  describe "encrypt_vault/2" do
    test "flips vault to encrypting and enqueues EncryptVault worker", %{user: user, vault: vault} do
      assert {:ok, updated} = Crypto.encrypt_vault(vault, user)
      assert updated.encrypted == true
      assert updated.encryption_status == "encrypting"
      assert updated.last_toggle_at != nil
      assert_enqueued(worker: EncryptVault, args: %{"vault_id" => vault.id, "user_id" => user.id, "cursor" => 0})
    end

    test "returns :bad_status when already encrypted", %{user: user, vault: vault} do
      {:ok, vault} = Vault.update_status(vault, "encrypted")
      assert {:error, :bad_status} = Crypto.encrypt_vault(vault, user)
    end

    test "returns :bad_status when currently encrypting", %{user: user, vault: vault} do
      {:ok, vault} = Vault.update_status(vault, "encrypting")
      assert {:error, :bad_status} = Crypto.encrypt_vault(vault, user)
    end

    test "returns :cooldown when last_toggle_at within 7 days", %{user: user, vault: vault} do
      recent = DateTime.utc_now() |> DateTime.add(-3, :day)
      {:ok, vault} = vault |> Ecto.Changeset.change(%{last_toggle_at: recent}) |> Repo.update()
      assert {:error, :cooldown} = Crypto.encrypt_vault(vault, user)
    end

    test "succeeds when last_toggle_at > 7 days ago", %{user: user, vault: vault} do
      old = DateTime.utc_now() |> DateTime.add(-8, :day)
      {:ok, vault} = vault |> Ecto.Changeset.change(%{last_toggle_at: old}) |> Repo.update()
      assert {:ok, _} = Crypto.encrypt_vault(vault, user)
    end
  end
end
