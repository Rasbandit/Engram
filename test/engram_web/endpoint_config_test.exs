defmodule EngramWeb.EndpointConfigTest do
  use ExUnit.Case, async: true

  test "websocket_check_origin runtime value is valid shape" do
    # In :test/:dev env this key is unset — false is the default, which is fine.
    # In :prod env (at startup) runtime.exs sets it to a non-empty list.
    # Config is read at request time via the MFA callback in endpoint.ex.
    origin = Application.get_env(:engram, :websocket_check_origin, false)
    assert origin == false or (is_list(origin) and origin != [])
  end

  test "Endpoint.check_origin/1 allows listed origins" do
    Application.put_env(:engram, :websocket_check_origin, ["https://app.engram.dev", "app://obsidian.md"])
    on_exit(fn -> Application.delete_env(:engram, :websocket_check_origin) end)

    assert EngramWeb.Endpoint.check_origin("https://app.engram.dev")
    assert EngramWeb.Endpoint.check_origin("app://obsidian.md")
    refute EngramWeb.Endpoint.check_origin("https://evil.com")
  end

  test "Endpoint.check_origin/1 blocks all when config is false" do
    Application.put_env(:engram, :websocket_check_origin, false)
    on_exit(fn -> Application.delete_env(:engram, :websocket_check_origin) end)

    refute EngramWeb.Endpoint.check_origin("https://app.engram.dev")
  end
end
