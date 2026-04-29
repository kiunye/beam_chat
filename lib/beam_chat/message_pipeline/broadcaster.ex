defmodule BeamChat.MessagePipeline.Broadcaster do
  @moduledoc """
  Broadcasts persisted messages to Phoenix.PubSub for real-time delivery.

  After messages are persisted to the database, this stage broadcasts them
  to the appropriate room topics so LiveView clients can receive them in real-time.
  """

  @type persisted_message :: %BeamChat.Messages.Message{}

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
    # Broadcast to the room topic
    topic = "room:#{message.room_id}"
    event = {:new_message, message}

    Phoenix.PubSub.broadcast(BeamChat.PubSub, topic, event)

    # Also update any presence/typing information if needed
    # For now, we just broadcast the message
  end
end
