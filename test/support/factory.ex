defmodule Engram.Factory do
  use ExMachina.Ecto, repo: Engram.Repo

  def user_factory do
    %Engram.Accounts.User{
      email: sequence(:email, &"user#{&1}@test.com"),
      password_hash: Argon2.hash_pwd_salt("password123"),
      display_name: sequence(:display_name, &"User #{&1}"),
      clerk_id: nil
    }
  end

  def note_factory do
    %Engram.Notes.Note{
      path: sequence(:path, &"test/note-#{&1}.md"),
      title: sequence(:title, &"Note #{&1}"),
      content: "# Test note content",
      folder: "test",
      tags: [],
      version: 1,
      content_hash: :crypto.hash(:sha256, "# Test note content") |> Base.encode16(case: :lower),
      embed_hash: nil,
      user: build(:user)
    }
  end

  def api_key_factory do
    %Engram.Accounts.ApiKey{
      key_hash:
        :crypto.hash(:sha256, "engram_" <> sequence(:key, &"key#{&1}"))
        |> Base.encode16(case: :lower),
      name: sequence(:key_name, &"Key #{&1}"),
      user: build(:user)
    }
  end

  def plan_factory do
    %Engram.Billing.Plan{
      name: sequence(:plan_name, &"plan_#{&1}"),
      limits: %{
        "max_vaults" => 1,
        "cross_vault_search" => false,
        "vault_scoped_keys" => false
      }
    }
  end

  def user_override_factory do
    %Engram.Billing.UserOverride{
      user: build(:user),
      overrides: %{},
      reason: "test override"
    }
  end

  def subscription_factory do
    %Engram.Billing.Subscription{
      stripe_customer_id: sequence(:stripe_customer_id, &"cus_test#{&1}"),
      stripe_subscription_id: sequence(:stripe_sub_id, &"sub_test#{&1}"),
      tier: "starter",
      status: "active",
      current_period_end: DateTime.add(DateTime.utc_now(), 30, :day),
      user: build(:user)
    }
  end
end
