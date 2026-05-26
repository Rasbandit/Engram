defmodule Engram.MailerTest do
  use Engram.DataCase, async: false

  import Mox

  alias Engram.Mailer

  setup :verify_on_exit!

  setup do
    prev_provider = Application.get_env(:engram, :email_provider)
    Application.put_env(:engram, :email_provider, Engram.Email.ProviderMock)

    on_exit(fn ->
      if is_nil(prev_provider),
        do: Application.delete_env(:engram, :email_provider),
        else: Application.put_env(:engram, :email_provider, prev_provider)
    end)

    :ok
  end

  describe "send_welcome/1" do
    test "sends a welcome email to the user's address" do
      user = insert(:user)

      expect(Engram.Email.ProviderMock, :send, fn to, subject, html, _opts ->
        assert to == user.email
        assert subject =~ "Welcome"
        assert html =~ "Engram"
        :ok
      end)

      assert :ok = Mailer.send_welcome(user)
    end

    test "escapes HTML in the user's display name" do
      user = insert(:user, display_name: "<script>alert(1)</script>")

      expect(Engram.Email.ProviderMock, :send, fn _to, _subject, html, _opts ->
        refute html =~ "<script>alert(1)</script>"
        assert html =~ "&lt;script&gt;"
        :ok
      end)

      assert :ok = Mailer.send_welcome(user)
    end
  end
end
