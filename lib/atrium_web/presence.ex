defmodule AtriumWeb.Presence do
  @moduledoc """
  Tracks which channel each connected, nicked client is currently viewing, so
  `AtriumWeb.ChatLive` can show how many people are online per channel.
  """
  use Phoenix.Presence,
    otp_app: :atrium,
    pubsub_server: Atrium.PubSub
end
