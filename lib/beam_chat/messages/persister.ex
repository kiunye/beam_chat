defmodule BeamChat.Messages.Persister do
  @moduledoc """
  Persists messages to the database.

  Valid messages in a list are written with a single `Repo.insert_all/3` when possible,
  falling back to one `Repo.insert/1` per map on encoding or DB errors. Invalid shapes
  still use per-row handling. `persist_ordered/1` returns one result per input.
  """

  require Logger

  alias BeamChat.Direct.DirectMessage
  alias BeamChat.Messages.Message
  alias BeamChat.Repo

  @type pipeline_id :: pos_integer() | Ecto.UUID.t()

  @type message :: %{
          kind: :room | :direct,
          user_id: pipeline_id(),
          content: String.t(),
          inserted_at: DateTime.t() | nil,
          room_id: pipeline_id() | nil,
          conversation_id: pipeline_id() | nil,
          metadata: map() | nil,
          moderation_flag: String.t() | nil
        }

  @type persisted_message :: %Message{} | %DirectMessage{}

  @doc """
  Persists each message in order. Returns `{:ok, row}` or `{:error, reason}` per slot,
  same length as the input list.
  """
  @spec persist_ordered([term()]) :: [{:ok, persisted_message()} | {:error, term()}]
  def persist_ordered([]), do: []

  def persist_ordered(messages) when is_list(messages) do
    if batch_insert_eligible?(messages) do
      try do
        batch_insert_all!(messages)
      rescue
        e in Postgrex.Error ->
          log_batch_fallback(e)
          Enum.map(messages, &persist_one/1)

        e in DBConnection.EncodeError ->
          log_batch_fallback(e)
          Enum.map(messages, &persist_one/1)
      end
    else
      Enum.map(messages, &persist_one/1)
    end
  end

  @doc """
  Returns only successfully persisted rows (legacy helper for tests and batch summaries).
  """
  @spec batch_execute([message()]) :: {:ok, [persisted_message()]}
  def batch_execute(messages) when is_list(messages) do
    persisted =
      messages
      |> persist_ordered()
      |> Enum.flat_map(fn
        {:ok, row} -> [row]
        {:error, _} -> []
      end)

    {:ok, persisted}
  end

  @doc """
  Persists a single message, preloads its sender, and emits pipeline telemetry.
  The caller broadcasts the returned row itself (room vs direct messages are
  broadcast on different topics by schema-typed functions, so the broadcast
  stays at the call site).

  Accepts any message-shape map (`%{kind: :room | :direct, ...}`). Shape
  validation matches `persist_ordered/1`'s list behavior: unrecognized shapes
  return `{:error, {:persist_failed, :invalid_message_shape}}`, and
  kind/destination consistency is enforced by `Validator` before this is ever
  called.

  Returns `{:ok, row}` or `{:error, {:persist_failed, reason}}` — the same
  shape both `Rooms.send_message/3` and `Direct.send_message/3` expose.
  """
  @spec persist_and_preload(map()) ::
          {:ok, persisted_message()} | {:error, {:persist_failed, term()}}
  def persist_and_preload(data) when is_map(data) do
    case persist_ordered([data]) do
      [{:ok, row}] ->
        row = Repo.preload(row, :sender)

        :telemetry.execute(
          [:beam_chat, :message_pipeline, :persisted],
          %{count: 1, failed_count: 0},
          %{}
        )

        {:ok, row}

      [{:error, reason} | _] ->
        :telemetry.execute(
          [:beam_chat, :message_pipeline, :failed],
          %{count: 1},
          %{reason: inspect(reason)}
        )

        {:error, {:persist_failed, reason}}
    end
  end

  defp batch_insert_eligible?(messages) do
    Enum.all?(messages, fn
      %{kind: :room, room_id: _, user_id: _, content: _} -> true
      %{kind: :direct, conversation_id: _, user_id: _, content: _} -> true
      # Default kind is :room — accept `room_id` maps without an explicit
      # `:kind` key for backward compatibility with room-message call sites.
      %{room_id: _, user_id: _, content: _} -> true
      _ -> false
    end)
  end

  defp batch_insert_all!(messages) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # A single call may contain both room messages and DMs. Insert per-kind
    # so each subset maps to one `insert_all` against the right schema, then
    # reassemble results in the original input order so `persist_ordered`'s
    # contract holds.
    #
    # `insert_kind/3` returns results in the same order as its input subset.
    # We pass two queues (room, direct) into `Enum.map_reduce/3` and pop
    # from the front of whichever queue matches each input's kind.
    room_initial = insert_kind(:room, Enum.filter(messages, &room_kind?/1), now)
    direct_initial = insert_kind(:direct, Enum.filter(messages, &direct_kind?/1), now)

    {results, {_room_left, _direct_left}} =
      Enum.map_reduce(messages, {room_initial, direct_initial}, fn msg, {room_q, direct_q} ->
        case Map.get(msg, :kind, :room) do
          :room ->
            [head | tail] = room_q
            {head, {tail, direct_q}}

          :direct ->
            [head | tail] = direct_q
            {head, {room_q, tail}}
        end
      end)

    results
  end

  defp room_kind?(%{kind: :direct}), do: false
  defp room_kind?(_), do: true

  defp direct_kind?(%{kind: :direct}), do: true
  defp direct_kind?(_), do: false

  defp insert_kind(_kind, [], _now), do: []

  defp insert_kind(:room, kind_messages, now) do
    rows = build_room_rows(kind_messages, now)
    {_count, returned} = Repo.insert_all(Message, rows, returning: true)
    Enum.map(returned, &{:ok, &1})
  end

  defp insert_kind(:direct, kind_messages, now) do
    rows = build_direct_rows(kind_messages, now)

    {_count, returned} =
      Repo.insert_all(DirectMessage, rows, returning: true)

    Enum.map(returned, &{:ok, &1})
  end

  defp build_room_rows(messages, now) do
    Enum.map(messages, fn data ->
      data = Map.put_new(data, :inserted_at, nil)

      inserted_at =
        case data.inserted_at do
          %DateTime{} = dt -> DateTime.truncate(dt, :second)
          _ -> now
        end

      %{
        room_id: data.room_id,
        sender_id: data.user_id,
        content: data.content,
        content_type: "text",
        metadata: Map.get(data, :metadata) || %{},
        is_deleted: false,
        moderation_flag: Map.get(data, :moderation_flag),
        inserted_at: inserted_at
      }
    end)
  end

  defp build_direct_rows(messages, now) do
    Enum.map(messages, fn data ->
      data = Map.put_new(data, :inserted_at, nil)

      inserted_at =
        case data.inserted_at do
          %DateTime{} = dt -> DateTime.truncate(dt, :second)
          _ -> now
        end

      %{
        conversation_id: data.conversation_id,
        sender_id: data.user_id,
        content: data.content,
        content_type: "text",
        metadata: Map.get(data, :metadata) || %{},
        is_read: false,
        is_deleted: false,
        inserted_at: inserted_at
      }
    end)
  end

  defp log_batch_fallback(exception) do
    Logger.warning(
      "message_pipeline.batch_insert_fallback reason=#{Exception.message(exception)}"
    )
  end

  defp persist_one(%{kind: :direct} = data) do
    data = Map.put_new(data, :inserted_at, nil)

    case persist_dm(data) do
      {:ok, %DirectMessage{} = _row} = ok ->
        ok

      {:error, reason} = err ->
        Logger.warning(
          "message_pipeline.persist_failed conversation_id=#{inspect(Map.get(data, :conversation_id))} reason=#{inspect(reason)}"
        )

        err
    end
  end

  defp persist_one(%{room_id: _, user_id: _, content: _} = data) do
    data = Map.put_new(data, :inserted_at, nil)

    case persist_message(data) do
      {:ok, %Message{} = _row} = ok ->
        ok

      {:error, reason} = err ->
        Logger.warning(
          "message_pipeline.persist_failed room_id=#{inspect(Map.get(data, :room_id))} reason=#{inspect(reason)}"
        )

        err
    end
  end

  defp persist_one(data) when is_map(data) do
    Logger.warning("message_pipeline.persist_skipped reason=invalid_message_shape")
    {:error, :invalid_message_shape}
  end

  defp persist_one(_) do
    {:error, :invalid_message_data}
  end

  defp persist_message(%{
         room_id: room_id,
         user_id: user_id,
         content: content,
         inserted_at: inserted_at
       }) do
    changeset =
      %Message{}
      |> Message.changeset(%{
        room_id: room_id,
        sender_id: user_id,
        content: content,
        inserted_at: inserted_at,
        content_type: "text"
      })

    Repo.insert(changeset)
  end

  defp persist_dm(%{
         conversation_id: conversation_id,
         user_id: user_id,
         content: content,
         inserted_at: inserted_at
       }) do
    changeset =
      %DirectMessage{}
      |> DirectMessage.changeset(%{
        conversation_id: conversation_id,
        sender_id: user_id,
        content: content,
        inserted_at: inserted_at,
        content_type: "text"
      })

    Repo.insert(changeset)
  end
end
