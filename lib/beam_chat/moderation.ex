defmodule BeamChat.Moderation do
  @moduledoc """
  Moderation context: the rule set, the rule-engine cache, and the
  moderation log.

  The log is load-bearing (PRD §2.5): every block or flag from a send path
  writes an entry as part of the same operation as the block or flag
  itself. Manual admin actions (bans, role changes, manual wallet credits,
  room moderation) write entries here too, with the acting admin as
  actor and no originating rule. The prior build shipped a log table that
  nothing wrote to; these helpers close exactly that gap.
  """

  import Ecto.Query

  alias BeamChat.Accounts.User
  alias BeamChat.Moderation.ModerationLog
  alias BeamChat.Moderation.ModerationRule
  alias BeamChat.Moderation.RuleEngine
  alias BeamChat.Repo

  @content_preview_length 280

  ### Moderation Rules

  @doc "Lists all active moderation rules."
  def list_active_rules do
    Repo.all(from(r in ModerationRule, where: r.is_active == true))
  end

  @doc "Lists every rule (admin Settings view), newest first."
  def list_rules do
    Repo.all(from(r in ModerationRule, order_by: [desc: r.inserted_at]))
  end

  @doc "Gets a specific moderation rule by ID."
  def get_rule!(id), do: Repo.get!(ModerationRule, id)

  @doc "Creates a new moderation rule."
  def create_rule(attrs) do
    %ModerationRule{}
    |> ModerationRule.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Updates an existing moderation rule."
  def update_rule(id, attrs) do
    Repo.get!(ModerationRule, id)
    |> ModerationRule.changeset(attrs)
    |> Repo.update()
  end

  @doc "Deletes a moderation rule."
  def delete_rule(id) do
    Repo.get!(ModerationRule, id)
    |> Repo.delete()
  end

  ### Rule Engine Integration

  @doc """
  Triggers a refresh of the rule engine cache.

  Called by the Oban refresh job to update the ETS snapshot owned by
  `BeamChat.Moderation.RuleEngine` with the latest rules from the
  database.
  """
  def refresh_rule_cache do
    RuleEngine.refresh_cache()
  end

  ### Moderation Logging

  @doc """
  Logs a moderation action.

  This is the single writer used by send paths and admin actions alike;
  callers running inside a transaction may call it directly so the log
  entry commits (or rolls back) with the operation it describes.
  """
  @spec log_moderation_action(map()) :: {:ok, ModerationLog.t()} | {:error, Ecto.Changeset.t()}
  def log_moderation_action(attrs) do
    %ModerationLog{}
    |> ModerationLog.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Log entry for a message blocked by the rule set (never persisted).

  `rule` is the originating rule from the engine; `content` is the blocked
  message, of which a short preview is stored so moderators can see *what*
  got blocked. Must be called inside the send operation — on failure the
  send fails with `{:log_failed, reason}` rather than silently skipping.
  """
  @spec log_blocked_message(keyword() | map()) ::
          {:ok, ModerationLog.t()} | {:error, Ecto.Changeset.t()}
  def log_blocked_message(attrs) do
    attrs = to_map(attrs)
    kind = Map.get(attrs, :kind, :room)

    log_moderation_action(%{
      target_type: target_type_for(kind),
      target_id: Map.get(attrs, :destination_id),
      action: "message_blocked",
      reason: Map.get(attrs, :reason),
      rule_id: rule_id(Map.get(attrs, :rule)),
      actor_id: nil,
      metadata: %{
        sender_id: Map.get(attrs, :sender_id),
        kind: kind,
        rule_name: rule_name(Map.get(attrs, :rule)),
        content_preview: content_preview(Map.get(attrs, :content))
      }
    })
  end

  @doc """
  Log entry for a message flagged by the rule set (persisted but marked).

  Call inside the same transaction as the message insert so the two commit
  or roll back together (PRD §2.5: never a separate step that can be
  skipped).
  """
  @spec log_flagged_message(keyword() | map()) ::
          {:ok, ModerationLog.t()} | {:error, Ecto.Changeset.t()}
  def log_flagged_message(attrs) do
    attrs = to_map(attrs)
    kind = Map.get(attrs, :kind, :room)

    log_moderation_action(%{
      target_type: "message",
      target_id: Map.get(attrs, :message_id),
      action: "message_flagged",
      reason: Map.get(attrs, :reason),
      rule_id: rule_id(Map.get(attrs, :rule)),
      actor_id: nil,
      metadata: %{
        sender_id: Map.get(attrs, :sender_id),
        kind: kind,
        rule_name: rule_name(Map.get(attrs, :rule))
      }
    })
  end

  @doc "Log entry for a manual admin action against a user (ban/unban/role)."
  @spec log_user_action(User.t(), User.t(), String.t(), String.t() | nil, map()) ::
          {:ok, ModerationLog.t()} | {:error, Ecto.Changeset.t()}
  def log_user_action(%User{id: actor_id}, %User{id: target_id}, action, reason, metadata \\ %{}) do
    log_moderation_action(%{
      target_type: "user",
      target_id: target_id,
      action: action,
      reason: reason,
      actor_id: actor_id,
      metadata: metadata
    })
  end

  @doc "Log entry for a manual wallet credit issued from admin Settings."
  @spec log_manual_credit(Ecto.UUID.t(), Ecto.UUID.t(), Decimal.t(), String.t(), Ecto.UUID.t()) ::
          {:ok, ModerationLog.t()} | {:error, Ecto.Changeset.t()}
  def log_manual_credit(actor_id, target_user_id, amount, note, txn_id) do
    log_moderation_action(%{
      target_type: "user",
      target_id: target_user_id,
      action: "wallet_manual_credit",
      reason: note,
      actor_id: actor_id,
      metadata: %{amount: Decimal.to_string(amount), txn_id: txn_id}
    })
  end

  @doc "Log entry for room-level moderation performed by a person."
  @spec log_room_action(User.t() | nil, Ecto.UUID.t(), String.t(), String.t() | nil, map()) ::
          {:ok, ModerationLog.t()} | {:error, Ecto.Changeset.t()}
  def log_room_action(actor, room_id, action, reason, metadata \\ %{}) do
    log_moderation_action(%{
      target_type: "room",
      target_id: room_id,
      action: action,
      reason: reason,
      actor_id: actor && actor.id,
      metadata: metadata
    })
  end

  @doc "Paginated moderation log, newest first (admin Settings view)."
  @spec list_logs(pos_integer(), non_neg_integer()) :: {list(ModerationLog.t()), boolean()}
  def list_logs(limit, offset \\ 0) when is_integer(limit) and limit > 0 do
    from(l in ModerationLog,
      order_by: [desc: l.inserted_at, desc: l.id],
      preload: [:actor],
      limit: ^(limit + 1),
      offset: ^offset
    )
    |> Repo.all()
    |> then(fn batch -> {Enum.take(batch, limit), length(batch) > limit} end)
  end

  defp target_type_for(:room), do: "room"
  defp target_type_for(:direct), do: "conversation"

  defp rule_id(%{id: id}) when is_binary(id), do: id
  defp rule_id(_), do: nil

  defp rule_name(%{name: name}) when is_binary(name), do: name
  defp rule_name(_), do: nil

  defp content_preview(content) when is_binary(content) do
    content |> String.slice(0, @content_preview_length)
  end

  defp content_preview(_), do: nil

  defp to_map(attrs) when is_map(attrs), do: attrs
  defp to_map(attrs) when is_list(attrs), do: Map.new(attrs)
end
