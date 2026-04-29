defmodule BeamChat.MessagePipeline.RuleEngineTest do
  # Shares global `:moderation_rules` ETS with the running app; `reload_rules_cache` hits Repo.
  use BeamChat.DataCase, async: false

  alias BeamChat.MessagePipeline.RuleEngine

  @msg %{room_id: 1, user_id: 2, content: "check https://evil.example/path", inserted_at: nil}

  describe "link_filter" do
    test "blocks when URL host matches a forbidden domain" do
      rule = %{
        id: "00000000-0000-4000-8000-000000000001",
        name: "links",
        type: "link_filter",
        config: %{action: "block", domains: ["evil.example"]},
        is_active: true
      }

      assert {:blocked, @msg, reason} =
               RuleEngine.apply_single_rule(:fake_tid, rule, @msg)

      assert reason =~ "evil.example"
    end

    test "allows message when URL does not match forbidden domains" do
      rule = %{
        id: "00000000-0000-4000-8000-000000000002",
        name: "links",
        type: "link_filter",
        config: %{action: "block", domains: ["other.example"]},
        is_active: true
      }

      assert %{} = result = RuleEngine.apply_single_rule(:fake_tid, rule, @msg)
      assert result == @msg
    end

    test "does not crash when URL has no host" do
      msg = %{@msg | content: "see https:///nohost"}

      rule = %{
        id: "00000000-0000-4000-8000-000000000003",
        name: "links",
        type: "link_filter",
        config: %{action: "block", domains: ["x.com"]},
        is_active: true
      }

      assert RuleEngine.apply_single_rule(:fake_tid, rule, msg) == msg
    end
  end

  describe "reload_rules_cache/0" do
    test "repopulates without deleting the named table" do
      _ = RuleEngine.ensure_rules_table()
      tid_before = :ets.whereis(:moderation_rules)
      assert :ok = RuleEngine.reload_rules_cache()
      assert :ets.whereis(:moderation_rules) == tid_before
    end
  end
end
