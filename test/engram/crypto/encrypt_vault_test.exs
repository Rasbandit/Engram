defmodule Engram.Crypto.EncryptVaultTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Crypto
  alias Engram.Vaults.Vault
  alias Engram.Workers.EncryptVault
  alias Engram.Repo

  setup do
    user = insert(:user, encryption_toggle_cooldown_days: 7)
    vault = insert(:vault, user: user, encrypted: false, encryption_status: "none")
    %{user: user, vault: vault}
  end

  defp set_cooldown(user, days) do
    user |> Ecto.Changeset.change(%{encryption_toggle_cooldown_days: days}) |> Repo.update!()
  end

  defp set_last_toggle(vault, ago_days) do
    ts = DateTime.utc_now() |> DateTime.add(-ago_days, :day)
    {:ok, v} = vault |> Ecto.Changeset.change(%{last_toggle_at: ts}) |> Repo.update()
    v
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

    test "returns :cooldown when last_toggle_at within configured cooldown", %{user: user, vault: vault} do
      vault = set_last_toggle(vault, 3)
      assert {:error, :cooldown} = Crypto.encrypt_vault(vault, user)
    end

    test "succeeds when last_toggle_at older than configured cooldown", %{user: user, vault: vault} do
      vault = set_last_toggle(vault, 8)
      assert {:ok, _} = Crypto.encrypt_vault(vault, user)
    end

    test "skips cooldown when user.encryption_toggle_cooldown_days is NULL", %{user: user, vault: vault} do
      user = set_cooldown(user, nil)
      vault = set_last_toggle(vault, 1)
      assert {:ok, _} = Crypto.encrypt_vault(vault, user)
    end

    test "skips cooldown when user.encryption_toggle_cooldown_days is 0", %{user: user, vault: vault} do
      user = set_cooldown(user, 0)
      vault = set_last_toggle(vault, 0)
      assert {:ok, _} = Crypto.encrypt_vault(vault, user)
    end

    test "honors a custom cooldown of 30 days", %{user: user, vault: vault} do
      user = set_cooldown(user, 30)
      vault = set_last_toggle(vault, 10)
      assert {:error, :cooldown} = Crypto.encrypt_vault(vault, user)
    end
  end
end
