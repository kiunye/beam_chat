defmodule BeamChat.MessagePipeline.Producer do
  @moduledoc """
  Injection helper for the Broadway message pipeline.

  The supervised `BeamChat.MessagePipeline` uses `Broadway.DummyProducer` — this module is
  **not** a `Broadway.Producer` implementation. Use `push_messages/2` from controllers,
  LiveView, or other callers to enqueue maps; each map becomes `Broadway.Message.data` after
  the producer wraps it.
  """

  @spec push_messages(Broadway.name(), [map()]) :: :ok
  def push_messages(broadway_name, messages) when is_list(messages) do
    Broadway.push_messages(broadway_name, messages)
  end
end
