defmodule BeamChat.Messages.Pipeline do
  @moduledoc """
  The single send path shared by room messages and 1:1 DMs (PRD §2.5):

  moderation rules run against the content, and on success the message is
  persisted and (when flagged) logged — **every block or flag writes a
  moderation log entry as part of the same operation, not as a separate
  step that can be skipped.**

  - A *blocked* message is rejected; the log entry is the send operation's
    side effect and a failed log write fails the send.
  - A *flagged* message is stored with its `moderation_flag` and the log
    entry commits in the same database transaction as the message row.
  - A clean message persists through `BeamChat.Messages.Persister`.

  The caller broadcasts the returned row itself (rooms and conversations
  broadcast on different topics).
  """

  require Logger

  alias BeamChat.Direct.DirectMessage
  alias BeamChat.Messages.Message
  alias BeamChat.Messages.Persister
  alias BeamChat.Moderation
  alias BeamChat.Moderation.RuleEngine
  alias BeamChat.Repo

  @type validated :: map()

  @doc """
  Runs moderation over an already-validated message map and persists the
  outcome. Returns `{:ok, row}` (schema-typed, sender preloaded) or
  `{:error, term}`.
  """
  @spec run(validated()) ::
          {:ok, Message.t() | DirectMessage.t()} | {:error, term()}
  def run(validated) do
    case RuleEngine.apply_rules(validated) do
      {:blocked, _msg, rule, reason} ->
        log_blocked_or_fail(validated, rule, reason)

      {:flagged, msg, rule, reason} ->
        persist_flagged(msg, rule, reason)

      msg ->
        Persister.persist_and_preload(msg)
    end
  end

  defp log_blocked_or_fail(validated, rule, reason) do
    result =
      Moderation.log_blocked_message(
        kind: validated[:kind] || :room,
        destination_id: destination_id(validated),
        sender_id: validated[:user_id],
        rule: rule,
        reason: reason,
        content: validated[:content]
      )

    case result do
      {:ok, _log} ->
        {:error, {:blocked, reason}}

      {:error, cs} ->
        # The log is part of the send operation. If it cannot be written
        # the send fails loudly instead of silently skipping the trail.
        Logger.error("moderation: blocked-message log write failed: #{inspect(cs)}")
        {:error, {:log_failed, :blocked_message_log}}
    end
  end

  defp persist_flagged(msg, rule, reason) do
    Repo.transaction(fn ->
      with {:ok, row} <- insert_flagged_row(msg, reason),
           {:ok, _log} <-
             Moderation.log_flagged_message(
               kind: msg[:kind] || :room,
               message_id: row.id,
               sender_id: msg[:user_id],
               rule: rule,
               reason: reason
             ) do
        Repo.preload(row, :sender)
      else
        {:error, error} ->
          Repo.rollback(error)
      end
    end)
  end

  defp insert_flagged_row(%{kind: :room} = msg, reason) do
    %Message{}
    |> Message.changeset(%{
      room_id: msg[:room_id],
      sender_id: msg[:user_id],
      content: msg[:content],
      content_type: "text",
      moderation_flag: reason
    })
    |> Repo.insert()
  end

  defp insert_flagged_row(msg, reason) do
    %DirectMessage{}
    |> DirectMessage.changeset(%{
      conversation_id: msg[:conversation_id],
      sender_id: msg[:user_id],
      content: msg[:content],
      content_type: "text",
      moderation_flag: reason
    })
    |> Repo.insert()
  end

  defp destination_id(%{kind: :direct, conversation_id: id}), do: id
  defp destination_id(%{conversation_id: id}) when is_binary(id), do: id
  defp destination_id(%{room_id: id}), do: id
end
