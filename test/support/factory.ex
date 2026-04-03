defmodule Engram.Factory do
  use ExMachina.Ecto, repo: Engram.Repo

  def user_factory do
    %Engram.Accounts.User{
      email: sequence(:email, &"user#{&1}@test.com"),
      password_hash: Argon2.hash_pwd_salt("password123"),
      display_name: sequence(:display_name, &"User #{&1}")
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
      user: build(:user)
    }
  end

  def api_key_factory do
    %Engram.Accounts.ApiKey{
      key_hash: :crypto.hash(:sha256, "engram_" <> sequence(:key, &"key#{&1}")) |> Base.encode16(case: :lower),
      name: sequence(:key_name, &"Key #{&1}"),
      user: build(:user)
    }
  end
end
