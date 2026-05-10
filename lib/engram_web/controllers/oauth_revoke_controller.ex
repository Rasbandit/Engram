defmodule EngramWeb.OAuthRevokeController do
  @moduledoc """
  RFC 7009 token revocation. Always responds 200 (per §2.2) regardless
  of whether the token existed or was actually revoked — leaking that
  distinction would help attackers enumerate live tokens.

  Today only refresh tokens are stored server-side, so access-token
  revocation is silently no-op'd. Mismatched `client_id` is also a
  silent no-op (200, but the token is left intact).
  """
  use EngramWeb, :controller

  alias Engram.OAuth

  def revoke(conn, params) do
    _ =
      OAuth.revoke_token(
        params["token"],
        params["client_id"],
        params["token_type_hint"]
      )

    send_resp(conn, 200, "")
  end
end
