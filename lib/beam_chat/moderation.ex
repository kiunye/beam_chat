defmodule BeamChat.Moderation do
  @moduledoc """
  Moderation context for BEAM Chat.

  Handles moderation rules, rule engine integration, and moderation logging.
  """

  alias BeamChat.Moderation.ModerationLog
  alias BeamChat.Moderation.ModerationRule
  alias BeamChat.Moderation.RuleEngine
  alias BeamChat.Repo
  import Ecto.Query

  ### Moderation Rules

  @doc """
  Lists all active moderation rules.

  ## Examples

      iex> list_active_rules()
      [%ModerationRule{...}, ...]
  """
  def list_active_rules do
    Repo.all(from(r in ModerationRule, where: r.is_active == true))
  end

  @doc """
  Gets a specific moderation rule by ID.

  ## Examples

      iex> get_rule!(rule_id)
      %ModerationRule{}
  """
  def get_rule!(id), do: Repo.get!(ModerationRule, id)

  @doc """
  Creates a new moderation rule.

  ## Examples

      iex> create_rule(%{name: "profanity_filter", type: "word_filter", config: %{words: ["badword1", "badword2"]}})
      {:ok, %ModerationRule{}}
  """
  def create_rule(attrs) do
    %ModerationRule{}
    |> ModerationRule.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an existing moderation rule.

  ## Examples

      iex> update_rule rule_id, %{is_active: false}
      {:ok, %ModerationRule{}}
  """
  def update_rule(id, attrs) do
    rule = Repo.get!(ModerationRule, id)

    rule
    |> ModerationRule.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a moderation rule.

  ## Examples

      iex> delete_rule rule_id
      {:ok, %ModerationRule{}}
  """
  def delete_rule(id) do
    rule = Repo.get!(ModerationRule, id)
    Repo.delete(rule)
  end

  ### Moderation Logging

  @doc """
  Logs a moderation action.

  ## Examples

      iex> log_moderation_action(%{target_type: "message", target_id: msg_id, action: "block", reason: "spam"})
      {:ok, %ModerationLog{}}
  """
  def log_moderation_action(attrs) do
    %ModerationLog{}
    |> ModerationLog.changeset(attrs)
    |> Repo.insert()
  end

  ### Rule Engine Integration

  @doc """
  Triggers a refresh of the rule engine cache.

  This function is called by the Oban job to update the ETS cache
  owned by `BeamChat.Moderation.RuleEngine` with the latest rules from
  the database.
  """
  def refresh_rule_cache do
    RuleEngine.refresh_cache()
  end
end
