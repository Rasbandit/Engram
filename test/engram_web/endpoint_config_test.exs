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

  test "Endpoint.check_origin/1 allows all when config is false (origin checking disabled)" do
    Application.put_env(:engram, :websocket_check_origin, false)
    on_exit(fn -> Application.delete_env(:engram, :websocket_check_origin) end)

    assert EngramWeb.Endpoint.check_origin("https://anything.example.com")
  end

  # Phoenix.Socket.Transport calls the MFA with `URI.parse(origin)`, not the raw string.
  # Without URI handling, naive `origin in list` against string allowlist always rejects.
  test "Endpoint.check_origin/1 accepts URI struct (Phoenix transport contract)" do
    Application.put_env(:engram, :websocket_check_origin, [
      "http://engram.ax",
      "app://obsidian.md"
    ])

    on_exit(fn -> Application.delete_env(:engram, :websocket_check_origin) end)

    assert EngramWeb.Endpoint.check_origin(URI.parse("app://obsidian.md"))
    assert EngramWeb.Endpoint.check_origin(URI.parse("http://engram.ax"))
    refute EngramWeb.Endpoint.check_origin(URI.parse("https://evil.com"))
  end

  test "Endpoint.check_origin/1 accepts URI struct when checking is disabled" do
    Application.put_env(:engram, :websocket_check_origin, false)
    on_exit(fn -> Application.delete_env(:engram, :websocket_check_origin) end)

    assert EngramWeb.Endpoint.check_origin(URI.parse("https://anything.example.com"))
  end

  test "Endpoint.check_origin/1 normalizes URI with explicit non-default port" do
    Application.put_env(:engram, :websocket_check_origin, [
      "http://engram.ax:8080"
    ])

    on_exit(fn -> Application.delete_env(:engram, :websocket_check_origin) end)

    assert EngramWeb.Endpoint.check_origin(URI.parse("http://engram.ax:8080"))
    refute EngramWeb.Endpoint.check_origin(URI.parse("http://engram.ax"))
  end
end
