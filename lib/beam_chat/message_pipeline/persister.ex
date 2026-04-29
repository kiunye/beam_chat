defmodule BeamChat.MessagePipeline.Persister do
  @moduledoc """
  Persists messages to the database.

  Valid messages in a batch are written with a single `Repo.insert_all/3` when possible,
  falling back to one `Repo.insert/1` per map on encoding or DB errors. Invalid shapes
  still use per-row handling. `persist_ordered/1` returns one result per input for Broadway.
  """

  require Logger

  alias BeamChat.Messages.Message
  alias BeamChat.Repo

  @type pipeline_id :: pos_integer() | Ecto.UUID.t()

  @type message :: %{
          room_id: pipeline_id(),
          user_id: pipeline_id(),
          content: String.t(),
          inserted_at: DateTime.t() | nil
        }

  @type persisted_message :: %Message{}

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

  defp batch_insert_eligible?(messages) do
    Enum.all?(messages, &match?(%{room_id: _, user_id: _, content: _}, &1))
  end

  defp batch_insert_all!(messages) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
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

    {count, returned} = Repo.insert_all(Message, rows, returning: true)

    if count != length(messages) do
      raise "message_pipeline.batch_insert_count_mismatch: #{count}/#{length(messages)}"
    end

    Enum.zip(messages, returned)
    |> Enum.map(fn {_data, row} -> {:ok, message_from_insert_row(row)} end)
  end

  defp message_from_insert_row(%Message{} = row), do: row

  defp message_from_insert_row(row) when is_map(row) do
    struct!(Message, row)
  end

  defp log_batch_fallback(exception) do
    Logger.warning(
      "message_pipeline.batch_insert_fallback reason=#{Exception.message(exception)}"
    )
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
end
