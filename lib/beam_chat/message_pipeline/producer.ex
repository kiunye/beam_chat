defmodule BeamChat.MessagePipeline.Producer do
  @moduledoc """
  Injection helper for the Broadway message pipeline.

  The supervised `BeamChat.MessagePipeline` uses `Broadway.DummyProducer` — this module is
  **not** a `Broadway.Producer` implementation. Use `push_messages/2` from controllers,
  LiveView, or other callers to enqueue maps; each map becomes `Broadway.Message.data` after
  the producer wraps it.
  """

  # This wrapper exists to:
  #   1. Document the canonical entry point for pushing into the pipeline.
  #   2. Loosen the input type from Broadway's `[%Broadway.Message{}]` spec
  #      to `[map()]` (plain data, wrapped by `Broadway.DummyProducer` at
  #      runtime).
  # See P2 #26 in SECURITY_REVIEW.md for the broader context.
  @spec push_messages(Broadway.name(), [map() | term()]) :: :ok
  def push_messages(broadway_name, messages) when is_list(messages) do
    Broadway.push_messages(broadway_name, messages)
  end
end
