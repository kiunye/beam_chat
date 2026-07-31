defmodule BeamChat.Workers.RefreshModerationCacheTest do
  use BeamChat.DataCase, async: true

  alias BeamChat.Workers.RefreshModerationCache

  describe "perform/1" do
    test "refreshes the moderation rules cache (P2 #21)" do
      assert :ok = RefreshModerationCache.perform(%Oban.Job{args: %{}})

      # reload_rules_cache/0 guarantees the named ETS table exists with a
      # rules snapshot after the call.
      assert :ets.whereis(:moderation_rules) != :undefined
    end
  end
end
