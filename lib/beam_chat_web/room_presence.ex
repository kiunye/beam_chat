defmodule BeamChatWeb.RoomPresence do
  @moduledoc false
  use Phoenix.Presence,
    otp_app: :beam_chat,
    pubsub_server: BeamChat.PubSub
end
