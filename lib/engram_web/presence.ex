defmodule EngramWeb.Presence do
  use Phoenix.Presence,
    otp_app: :engram,
    pubsub_server: Engram.PubSub
end
