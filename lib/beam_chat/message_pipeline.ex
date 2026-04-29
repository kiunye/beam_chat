defmodule BeamChat.MessagePipeline do
  @moduledoc """
  Broadway message pipeline for processing chat messages.

  Stages (implemented in callbacks, not separate processor modules):

  1. `handle_message/3` — validate, moderation rules, then route to the default batcher
  2. `handle_batch/4` — persist in batches, broadcast over PubSub

  The supervised producer is `Broadway.DummyProducer`. Enqueue maps from app code with
  `BeamChat.MessagePipeline.Producer.push_messages/2` or `Broadway.push_messages/2`.
  """

  use Broadway

  alias BeamChat.MessagePipeline.Broadcaster
  alias BeamChat.MessagePipeline.Persister
  alias BeamChat.MessagePipeline.RuleEngine
  alias BeamChat.MessagePipeline.Validator
  alias BeamChat.Repo
  alias Broadway.Message

  def start_link(opts \\ []) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    Broadway.start_link(__MODULE__,
      name: name,
      producer: [
        module: {Broadway.DummyProducer, []},
        concurrency: 1
      ],
      processors: [
        default: [concurrency: System.schedulers_online()]
      ],
      batchers: [
        default: [
          concurrency: max(System.schedulers_online() * 2, 2),
          batch_size: 50,
          batch_timeout: 5_000
        ]
      ]
    )
  end

  @impl true
  def handle_message(_processor, %Message{} = message, _context) do
    case Validator.validate(message.data) do
      {:error, reason} ->
        Message.failed(message, reason)

      {:ok, data} ->
        tid = RuleEngine.ensure_rules_table()

        case RuleEngine.apply_rules(tid, data) do
          {:blocked, _msg, reason} ->
            Message.failed(message, {:blocked, reason})

          {:flagged, moderated, _reason} ->
            message
            |> Message.put_data(moderated)
            |> Message.put_batcher(:default)

          moderated when is_map(moderated) ->
            message
            |> Message.put_data(moderated)
            |> Message.put_batcher(:default)
        end
    end
  end

  @impl true
  def handle_batch(:default, messages, _batch_info, _context) do
    maps = Enum.map(messages, & &1.data)
    results = Persister.persist_ordered(maps)

    zipped = Enum.zip(messages, results)

    persisted =
      Enum.flat_map(zipped, fn
        {_msg, {:ok, row}} -> [row]
        {_msg, {:error, _}} -> []
      end)

    # Enrich once per persisted batch so LiveView clients can stream
    # without per-client DB preloads.
    persisted = Repo.preload(persisted, :sender)

    Broadcaster.broadcast(persisted)

    Enum.map(zipped, fn
      {msg, {:ok, _row}} ->
        msg

      {msg, {:error, reason}} ->
        Message.failed(msg, {:persist_failed, reason})
    end)
  end

  @impl true
  def handle_failed(messages, _context) do
    messages
  end
end
