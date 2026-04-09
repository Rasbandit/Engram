defmodule EngramWeb.EndpointConfigTest do
  use ExUnit.Case, async: true

  @compile_time_origin Application.compile_env(:engram, :websocket_check_origin, false)

  test "websocket_check_origin compile value is documented" do
    # In :test env this is false — that is expected and fine.
    # In :prod env (release build) it must be a non-empty list of allowed origins.
    # This test asserts the shape is valid: false (test/dev) or a non-empty list (prod).
    assert @compile_time_origin == false or
             (is_list(@compile_time_origin) and @compile_time_origin != [])
  end
end
