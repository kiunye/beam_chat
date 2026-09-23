defmodule BeamChat.Moderation.RuleEngineTest do
  # Shares global `:moderation_rules` ETS with the running app; `refresh_cache` hits Repo.
  use BeamChat.DataCase, async: false

  alias BeamChat.Moderation.RuleEngine

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
               RuleEngine.apply_single_rule(rule, @msg)

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

      assert %{} = result = RuleEngine.apply_single_rule(rule, @msg)
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

      assert RuleEngine.apply_single_rule(rule, msg) == msg
    end
  end

  describe "rate_limit" do
    # The counters table is shared with the running app's RuleEngine, so each
    # test uses a unique user_id to avoid cross-test interference.
    defp rate_msg(user_id), do: %{room_id: 1, user_id: user_id, content: "hi", inserted_at: nil}

    defp rate_rule(max_count, window_seconds) do
      %{type: "rate_limit", config: %{max_count: max_count, window_seconds: window_seconds}}
    end

    test "allows up to max_count messages per window, then blocks" do
      user_id = :erlang.unique_integer([:positive])
      msg = rate_msg(user_id)
      rule = rate_rule(2, 60)

      assert RuleEngine.apply_single_rule(rule, msg) == msg
      assert RuleEngine.apply_single_rule(rule, msg) == msg

      assert {:blocked, ^msg, reason} = RuleEngine.apply_single_rule(rule, msg)
      assert reason =~ "Rate limit exceeded: 2/2"
    end

    test "starts a fresh window (and resets the counter) when the window expires" do
      user_id = :erlang.unique_integer([:positive])
      msg = rate_msg(user_id)
      rule = rate_rule(1, 60)

      assert RuleEngine.apply_single_rule(rule, msg) == msg
      assert {:blocked, ^msg, _reason} = RuleEngine.apply_single_rule(rule, msg)

      # Age the window entry out by rewriting its start into the past
      # (deterministic — no sleep). The next message must open a new window
      # and pass.
      expired_start = System.system_time(:millisecond) - 61_000
      key = {user_id, :message_count}
      true = :ets.insert(:moderation_rate_counters, {key, 99, expired_start})

      assert RuleEngine.apply_single_rule(rule, msg) == msg

      # The reset restarts counting from 1, so the very next message blocks.
      assert {:blocked, ^msg, _reset_reason} = RuleEngine.apply_single_rule(rule, msg)
    end

    test "refresh_cache keeps rate-limit counters intact" do
      user_id = :erlang.unique_integer([:positive])
      msg = rate_msg(user_id)
      rule = rate_rule(1, 60)

      assert RuleEngine.apply_single_rule(rule, msg) == msg
      assert :ok = RuleEngine.refresh_cache()

      assert {:blocked, ^msg, _reason} = RuleEngine.apply_single_rule(rule, msg)
    end
  end

  describe "refresh_cache/0" do
    test "repopulates without deleting the named table" do
      tid_before = :ets.whereis(:moderation_rules)
      assert :ok = RuleEngine.refresh_cache()
      assert :ets.whereis(:moderation_rules) == tid_before
    end
  end

  describe "malformed rule resilience" do
    # `apply_single_rule/2` is matched with atom-key configs; these tests
    # hand it raw configs (as a direct caller would) to prove a malformed
    # rule degrades to pass-through instead of crashing the hot path.

    test "pattern rule with a string pattern blocks matching content" do
      rule = %{
        type: "pattern",
        config: %{patterns: ["^spam"]}
      }

      assert {:blocked, _msg, reason} =
               RuleEngine.apply_single_rule(rule, %{@msg | content: "spam everywhere"})

      assert reason =~ "spam"
    end

    test "pattern rule with an invalid regex does not crash and passes the message" do
      rule = %{
        type: "pattern",
        config: %{patterns: ["("]}
      }

      assert RuleEngine.apply_single_rule(rule, @msg) == @msg
    end

    test "word_filter with a non-binary word entry does not crash and still blocks real words" do
      rule = %{
        type: "word_filter",
        config: %{words: [123, "bad"]}
      }

      assert {:blocked, _msg, reason} =
               RuleEngine.apply_single_rule(rule, %{@msg | content: "this is bad"})

      assert reason =~ "bad"
    end

    test "pattern rule with an empty patterns list passes the message unchanged" do
      rule = %{
        type: "pattern",
        config: %{patterns: []}
      }

      assert RuleEngine.apply_single_rule(rule, @msg) == @msg
    end

    # Reproduces the production cache path: `normalize_config/1` compiles
    # DB pattern strings into `%Regex{}` at cache-load time, so the block
    # reason must interpolate the pattern *source* — `String.Chars` is not
    # implemented for `Regex`, and `#{}` on a compiled pattern used to raise
    # `Protocol.UndefinedError` on exactly the messages the rule blocks.
    test "pattern rule with a compiled regex (cache shape) blocks with a valid reason" do
      rule = %{
        type: "pattern",
        config: %{patterns: [~r/^spam/]}
      }

      assert {:blocked, _msg, reason} =
               RuleEngine.apply_single_rule(rule, %{@msg | content: "spam everywhere"})

      assert reason =~ "spam"
    end
  end
end
