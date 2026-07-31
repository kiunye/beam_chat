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

  require Logger

  alias BeamChat.MessagePipeline.Broadcaster
  alias BeamChat.MessagePipeline.Persister
  alias BeamChat.MessagePipeline.RuleEngine
  alias BeamChat.MessagePipeline.Validator
  alias BeamChat.Repo
  alias Broadway.Message

  @telemetry_events [:beam_chat, :message_pipeline]

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

    failed_count = length(messages) - length(persisted)

    :telemetry.execute(
      @telemetry_events ++ [:persisted],
      %{count: length(persisted), failed_count: failed_count},
      %{}
    )

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
    Enum.each(messages, fn %Message{} = message ->
      reason = failed_reason(message)

      Logger.warning("message_pipeline: dropping failed message",
        id: message_id(message),
        reason: format_reason(reason)
      )

      :telemetry.execute(
        @telemetry_events ++ [:failed],
        %{count: 1},
        %{reason: format_reason(reason)}
      )
    end)

    messages
  end

  defp failed_reason(%Message{status: {:failed, reason}}), do: reason
  defp failed_reason(_message), do: :unknown

  defp message_id(%Message{data: data}) when is_map(data) do
    Map.get(data, :id) || Map.get(data, "id")
  end

  defp message_id(_message), do: nil

  defp format_reason(reason) when is_atom(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
