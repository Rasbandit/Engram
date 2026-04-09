defmodule EngramWeb.Plugs.AuthJwtIntegrationTest do
  use EngramWeb.ConnCase, async: true

  # Verifies that the Auth plug actually enforces iss/aud on a real route,
  # not just that Token.verify_and_validate/1 returns an error in isolation.
  test "request with wrong-issuer JWT is rejected at the router level" do
    signer = Joken.Signer.create("HS256", Application.get_env(:joken, :default_signer))
    claims = %{"user_id" => 999, "iss" => "other_app", "aud" => "engram", "exp" => Joken.current_time() + 3600}
    {:ok, bad_token} = Joken.Signer.sign(claims, signer)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{bad_token}")
      |> get("/api/me")

    assert conn.status == 401
  end
end
