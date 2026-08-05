defmodule BeamChatWeb.RoomPresence do
  @moduledoc """
  Cluster-wide presence for chat rooms.

  Phoenix.Presence replicates presence CRDT deltas over `BeamChat.PubSub`, so
  users tracked on one node appear on every connected node. Presence is the
  sole room-membership mechanism — there is no per-room process layer.
  """

  use Phoenix.Presence,
    otp_app: :beam_chat,
    pubsub_server: BeamChat.PubSub
end
