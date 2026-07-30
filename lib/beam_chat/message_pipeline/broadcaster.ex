defmodule BeamChat.MessagePipeline.Broadcaster do
  @moduledoc """
  Broadcasts persisted messages to Phoenix.PubSub for real-time delivery.

  After messages are persisted to the database, this stage broadcasts them
  to the appropriate topics so LiveView clients can receive them in real-time.

  - `BeamChat.Messages.Message` (room) → `room:<room_id>`
  - `BeamChat.Direct.DirectMessage` (DM) → `conversation:<conversation_id>`
  """

  @type persisted_message :: %BeamChat.Messages.Message{} | %BeamChat.Direct.DirectMessage{}

  ### Broadway Batch Processor

  @spec broadcast([persisted_message()]) :: :ok
  def broadcast(messages) do
    Enum.each(messages, fn message ->
      broadcast_message(message)
    end)

    :ok
  end

  ### Message Broadcasting

  defp broadcast_message(%BeamChat.Messages.Message{} = message) do
    topic = "room:#{message.room_id}"
    event = {:new_message, message}

    Phoenix.PubSub.broadcast(BeamChat.PubSub, topic, event)
  end

  defp broadcast_message(%BeamChat.Direct.DirectMessage{} = message) do
    # Hand off to Direct so it uses the canonical "conversation:" topic
    # prefix. This keeps DMs routed through the same code path the legacy
    # `Direct.send_message/3` used.
    BeamChat.Direct.broadcast_new_message(message)
  end
end
