defmodule Engram.TokenTest do
  use ExUnit.Case, async: true

  alias Engram.Token

  test "generated tokens include iss and aud claims" do
    {:ok, _token, claims} = Token.generate_and_sign(%{"user_id" => 1})
    assert claims["iss"] == "engram"
    assert claims["aud"] == "engram"
  end

  test "tokens with wrong issuer are rejected" do
    signer = Joken.Signer.create("HS256", Application.get_env(:joken, :default_signer))
    claims = %{"user_id" => 1, "iss" => "other_app", "aud" => "engram", "exp" => Joken.current_time() + 3600}
    {:ok, token} = Joken.Signer.sign(claims, signer)
    assert {:error, _} = Token.verify_and_validate(token)
  end

  test "tokens with wrong audience are rejected" do
    signer = Joken.Signer.create("HS256", Application.get_env(:joken, :default_signer))
    claims = %{"user_id" => 1, "iss" => "engram", "aud" => "other_app", "exp" => Joken.current_time() + 3600}
    {:ok, token} = Joken.Signer.sign(claims, signer)
    assert {:error, _} = Token.verify_and_validate(token)
  end

  test "tokens missing iss claim are rejected" do
    signer = Joken.Signer.create("HS256", Application.get_env(:joken, :default_signer))
    claims = %{"user_id" => 1, "aud" => "engram", "exp" => Joken.current_time() + 3600}
    {:ok, token} = Joken.Signer.sign(claims, signer)
    assert {:error, _} = Token.verify_and_validate(token)
  end

  test "tokens missing aud claim are rejected" do
    signer = Joken.Signer.create("HS256", Application.get_env(:joken, :default_signer))
    claims = %{"user_id" => 1, "iss" => "engram", "exp" => Joken.current_time() + 3600}
    {:ok, token} = Joken.Signer.sign(claims, signer)
    assert {:error, _} = Token.verify_and_validate(token)
  end
end
