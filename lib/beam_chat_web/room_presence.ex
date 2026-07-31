defmodule BeamChatWeb.RoomPresence do
  @moduledoc """
  Cluster-wide presence for chat rooms.

  Phoenix.Presence replicates presence CRDT deltas over `BeamChat.PubSub`, so
  users tracked on one node appear on every connected node — replication does
  not depend on Horde (accepted limitation, SECURITY_REVIEW.md P3 #28).
  """

  use Phoenix.Presence,
    otp_app: :beam_chat,
    pubsub_server: BeamChat.PubSub
end
