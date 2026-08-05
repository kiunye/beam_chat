defmodule BeamChat.Workers.RefreshModerationCache do
  @moduledoc false

  use Oban.Worker, queue: :default, max_attempts: 1

  alias BeamChat.Moderation

  @impl Oban.Worker
  def perform(_job) do
    # Moderation.refresh_rule_cache/0 re-reads the moderation_rules table
    # into the named ETS cache owned by the supervised
    # BeamChat.Moderation.RuleEngine GenServer and returns :ok.
    # See SECURITY_REVIEW.md P2 #21.
    Moderation.refresh_rule_cache()
  end
end
