defmodule BeamChat.Moderation.RuleEngine do
  @moduledoc """
  Applies moderation rules to chat messages using an ETS cache.

  Runs as a supervised GenServer that owns the named `:moderation_rules`
  ETS table for the lifetime of the application. Rules are loaded from the
  `moderation_rules` table at boot and refreshed on demand via
  `refresh_cache/0` (called by the `BeamChat.Workers.RefreshModerationCache`
  Oban job). The message hot path never creates or reloads the table.

  The GenServer also owns a second, `:public` named table
  (`:moderation_rate_counters`) holding per-user fixed-window message
  counters for `rate_limit` rules. It is `:public` so sender processes can
  atomically bump counters on the hot path, and it is never wiped by cache
  refreshes. Counters are lost (and therefore reset) whenever the GenServer
  restarts.

  Rule config is normalized at cache-load time: `word_filter` word lists
  are validated and `pattern` regexes are compiled, with invalid entries
  skipped and logged. Boot still fails closed on schema-level database
  errors — only connection/ownership errors are tolerated (see
  `load_rules_into_cache/1`'s narrow rescue).

  Supported rule types:
  - word_filter: Blocks messages containing forbidden words
  - rate_limit: Limits messages per user per time window
  - link_filter: Blocks or flags messages with URLs
  - pattern: Blocks messages matching regex patterns
  """

  use GenServer

  require Logger

  @table :moderation_rules
  @counters :moderation_rate_counters
  @rules_snapshot_key :rules_snapshot

  @type rule :: %{
          id: Ecto.UUID.t(),
          name: String.t(),
          # "word_filter" | "rate_limit" | "link_filter" | "pattern"
          type: String.t(),
          config: map(),
          is_active: boolean()
        }

  @type pipeline_id :: pos_integer() | Ecto.UUID.t()

  @type message :: %{
          room_id: pipeline_id(),
          user_id: pipeline_id(),
          content: String.t(),
          inserted_at: DateTime.t() | nil
        }

  @type apply_rules_result ::
          message()
          | {:blocked, message(), String.t()}
          | {:flagged, message(), String.t()}

  @url_regex ~r/https?:\/\/[^\s]+/

  ## GenServer API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    tid =
      :ets.new(@table, [
        :named_table,
        :protected,
        read_concurrency: true,
        write_concurrency: true
      ])

    # The rate-limit counters live in a separate, `:public` table: the message
    # hot path runs in the sender's process and must bump counters directly
    # (a `:protected` table only allows writes from the owning GenServer).
    # Keeping them separate also means `load_rules_into_cache/1`'s
    # `:ets.delete_all_objects/1` never wipes rate-limit state.
    :ets.new(@counters, [
      :named_table,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    _ = load_rules_into_cache(tid)
    {:ok, %{tid: tid}}
  end

  ## Rule Loading and Caching

  @doc """
  Reloads the rules snapshot from the database into the named ETS table.

  Called by the Oban refresh job. The table itself is owned by this
  supervised GenServer and is never deleted.

  The boot-time load is best-effort: if the database is unavailable, the
  process does not crash and this returns `{:error, _}`. The cache stays
  stale (or empty at boot) until the Oban refresh job repopulates it on the
  next tick.
  """
  @spec refresh_cache() :: :ok | {:error, term()}
  def refresh_cache do
    GenServer.call(__MODULE__, :refresh_cache, 30_000)
  end

  @impl true
  def handle_call(:refresh_cache, _from, %{tid: tid} = state) do
    {:reply, load_rules_into_cache(tid), state}
  end

  defp load_rules_into_cache(tid) do
    :ets.delete_all_objects(tid)

    active_rules = BeamChat.Moderation.list_active_rules()
    true = :ets.insert(tid, {@rules_snapshot_key, Enum.map(active_rules, &normalize_rule/1)})

    :ok
  rescue
    e in [DBConnection.ConnectionError, DBConnection.OwnershipError] ->
      # Never let a DB hiccup take down the cache owner or the app. The cache
      # stays stale (or empty at boot) and the Oban refresh job repopulates it
      # on the next tick. Log loudly — an empty cache means messages pass
      # unmoderated, so this must be visible.
      Logger.error("moderation rules cache refresh failed: #{Exception.message(e)}")

      # Emit a fail-open metric so dashboards can alert on an empty cache
      # (messages passing unmoderated) instead of relying on log scraping.
      :telemetry.execute(
        [:beam_chat, :moderation_rules, :empty],
        %{count: 1},
        %{error: inspect(e)}
      )

      true = :ets.insert(tid, {@rules_snapshot_key, []})
      {:error, e}
  end

  # Ecto decodes the jsonb `config` column with string keys (Jason). The
  # rule clauses below pattern-match atom keys, so normalize the known
  # config keys at cache-load time. Unknown keys are passed through
  # unchanged — no atoms are created from arbitrary data.
  defp normalize_rule(%{config: config} = rule) when is_map(config) do
    %{rule | config: normalize_config(config)}
  end

  defp normalize_rule(rule), do: rule

  defp normalize_config(config) when is_map(config) do
    Map.new(config, fn
      {"words", v} -> {:words, normalize_words(v)}
      {"action", v} -> {:action, v}
      {"domains", v} -> {:domains, v}
      {"patterns", v} -> {:patterns, compile_patterns(v)}
      {"max_count", v} -> {:max_count, v}
      {"window_seconds", v} -> {:window_seconds, v}
      {k, v} -> {k, v}
    end)
  end

  # The jsonb `config` column arrives as strings via Jason. Words are
  # validated and patterns are compiled once at cache-load time so the ETS
  # snapshot never contains a non-binary word or a non-compilable regex —
  # the message hot path must never hit `Regex.match?/2` on a raw string.
  defp normalize_words(words) when is_list(words) do
    Enum.flat_map(words, fn
      w when is_binary(w) ->
        [w]

      other ->
        Logger.warning("moderation: skipping non-binary word entry #{inspect(other)}")
        []
    end)
  end

  defp normalize_words(_), do: []

  defp compile_patterns(patterns) when is_list(patterns) do
    Enum.flat_map(patterns, fn
      p when is_binary(p) ->
        case Regex.compile(p) do
          {:ok, re} ->
            [re]

          {:error, _} ->
            Logger.warning("moderation: skipping invalid pattern regex #{inspect(p)}")
            []
        end

      other ->
        Logger.warning("moderation: skipping non-binary pattern entry #{inspect(other)}")
        []
    end)
  end

  defp compile_patterns(_), do: []

  ## Rule Processing

  @doc """
  Applies the cached moderation rules to a message.

  Returns `message` unchanged if no rule matches, `{:blocked, message,
  reason}` when a rule rejects it, or `{:flagged, message, reason}` when a
  rule wants it flagged (persist but mark).
  """
  @spec apply_rules(message() | map()) :: apply_rules_result()
  def apply_rules(message) do
    case :ets.whereis(@table) do
      :undefined ->
        Logger.warning(
          "moderation_rules ETS table is missing; skipping moderation rule application"
        )

        message

      tid ->
        apply_rule_sequence(rules_from_table(tid), message)
    end
  end

  defp rules_from_table(tid) do
    case :ets.lookup(tid, @rules_snapshot_key) do
      [{@rules_snapshot_key, list}] when is_list(list) -> list
      _ -> []
    end
  end

  # Apply each rule in sequence.
  defp apply_rule_sequence(rules, message) do
    Enum.reduce(rules, message, fn rule, acc_message ->
      case acc_message do
        {:blocked, _msg, _reason} ->
          # Already blocked, keep the block reason
          acc_message

        {:flagged, msg, reason} ->
          merge_flagged_rule_result(safe_apply(rule, msg), reason)

        message ->
          # Not yet moderated, apply rule
          safe_apply(rule, message)
      end
    end)
  end

  # A rule must never take down the message hot path. Rule config comes
  # from the DB; if a rule misbehaves, log loudly and pass the message
  # through (fail-open, consistent with the empty-cache policy). Only the
  # config-driven crash classes are caught — anything else is a code bug
  # that should surface.
  defp safe_apply(rule, message) do
    apply_single_rule(rule, message)
  rescue
    e in [FunctionClauseError, ArgumentError, Protocol.UndefinedError] ->
      Logger.error(
        "moderation: rule #{inspect(rule.id || rule.name)} failed: #{Exception.message(e)}; skipping rule"
      )

      message
  end

  defp merge_flagged_rule_result({:blocked, msg2, reason2}, _prior), do: {:blocked, msg2, reason2}

  defp merge_flagged_rule_result({:flagged, msg2, reason2}, prior),
    do: {:flagged, msg2, prior <> "; " <> reason2}

  defp merge_flagged_rule_result(msg2, prior), do: {:flagged, msg2, prior}

  @spec apply_single_rule(rule(), message()) ::
          message()
          | {:blocked, message(), String.t()}
          | {:flagged, message(), String.t()}
  def apply_single_rule(
        %{
          type: "word_filter",
          config: %{words: forbidden_words}
        } = _rule,
        %{content: content} = message
      ) do
    # Word filter rule: check for forbidden words
    lower_content = String.downcase(content)

    forbidden_word =
      Enum.find(forbidden_words, &word_matches?(&1, lower_content))

    if forbidden_word do
      {:blocked, message, "Contains forbidden word: #{forbidden_word}"}
    else
      message
    end
  end

  def apply_single_rule(
        %{
          type: "rate_limit",
          config: %{max_count: max_count, window_seconds: window_seconds}
        } = _rule,
        %{user_id: user_id} = message
      ) do
    case :ets.whereis(@counters) do
      :undefined ->
        Logger.warning("moderation_rate_counters ETS table is missing; skipping rate limit rule")

        message

      _tid ->
        rate_limit_check(message, user_id, max_count, window_seconds)
    end
  end

  def apply_single_rule(
        %{
          type: "link_filter",
          config: %{action: action, domains: domains}
        } = _rule,
        %{content: content} = message
      ) do
    # Link filter rule: check for URLs
    urls = Regex.scan(@url_regex, content)

    if Enum.empty?(urls) do
      message
    else
      domains = List.wrap(domains)

      forbidden_match =
        Enum.find(urls, fn match ->
          url = match |> List.first() |> url_string()
          url != "" and url_matches_forbidden_domain?(url, domains)
        end)

      if forbidden_match do
        url = forbidden_match |> List.first() |> url_string()
        apply_link_action(message, action, url)
      else
        message
      end
    end
  end

  def apply_single_rule(
        %{
          type: "pattern",
          config: %{patterns: patterns}
        } = _rule,
        %{content: content} = message
      ) do
    # Pattern rule: check against regex patterns
    matched_pattern =
      Enum.find(patterns, &pattern_matches?(&1, content))

    if matched_pattern do
      {:blocked, message, "Matches forbidden pattern: #{pattern_source(matched_pattern)}"}
    else
      message
    end
  end

  def apply_single_rule(_rule, message) do
    # Unknown rule type, allow message through
    message
  end

  # Fixed-window counter: `{user_id, :message_count}` maps to
  # `{count, window_start_ms}`. Blocked messages do not increment the counter,
  # so a user may send at most `max_count` messages per window. The lookup /
  # reset race between concurrent senders is best-effort (the atomic
  # `:ets.update_counter/3` prevents lost increments inside an active window).
  defp rate_limit_check(message, user_id, max_count, window_seconds) do
    key = {user_id, :message_count}
    window_ms = :erlang.max(window_seconds, 0) * 1000
    now = System.system_time(:millisecond)

    case :ets.lookup(@counters, key) do
      [{^key, count, window_start}] when now - window_start < window_ms and count >= max_count ->
        {:blocked, message, "Rate limit exceeded: #{count}/#{max_count} messages"}

      [{^key, _count, window_start}] when now - window_start < window_ms ->
        _ = :ets.update_counter(@counters, key, {2, 1})
        message

      [{^key, _count, _expired_window_start}] ->
        true = :ets.insert(@counters, {key, 1, now})
        message

      [] ->
        true = :ets.insert(@counters, {key, 1, now})
        message
    end
  end

  # Tolerant matchers: direct callers may hand us raw (un-normalized) rule
  # configs, e.g. string patterns from the DB or a stray non-binary word.
  # Never raise on bad config — treat it as "no match" so the message
  # passes through.
  defp pattern_matches?(%Regex{} = re, content), do: Regex.match?(re, content)

  defp pattern_matches?(source, content) when is_binary(source) do
    case Regex.compile(source) do
      {:ok, re} -> Regex.match?(re, content)
      {:error, _} -> false
    end
  end

  defp pattern_matches?(_, _), do: false

  # The block reason must interpolate the pattern source, not the compiled
  # regex: `String.Chars` is not implemented for `Regex`, so `#{}` on a
  # compiled pattern would raise `Protocol.UndefinedError` on the exact
  # messages the rule is meant to block (cache path feeds `%Regex{}` here).
  defp pattern_source(%Regex{} = re), do: Regex.source(re)
  defp pattern_source(pattern) when is_binary(pattern), do: pattern

  defp word_matches?(word, lower_content) when is_binary(word),
    do: String.contains?(lower_content, String.downcase(word))

  defp word_matches?(_, _), do: false

  defp apply_link_action(message, "block", url),
    do: {:blocked, message, "Contains forbidden link: #{url}"}

  defp apply_link_action(message, "flag", url),
    do: {:flagged, message, "Contains link: #{url}"}

  defp apply_link_action(message, _, _), do: message

  defp url_string(u) when is_binary(u), do: u
  defp url_string(_), do: ""

  defp url_matches_forbidden_domain?(url, domains) when is_binary(url) and is_list(domains) do
    case URI.parse(url).host do
      host when is_binary(host) ->
        host_lc = String.downcase(host)

        Enum.any?(domains, fn d ->
          is_binary(d) and String.downcase(d) == host_lc
        end)

      _ ->
        false
    end
  end
end
