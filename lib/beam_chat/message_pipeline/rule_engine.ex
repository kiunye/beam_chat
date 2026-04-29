defmodule BeamChat.MessagePipeline.RuleEngine do
  @moduledoc """
  Applies moderation rules to chat messages using ETS cache.

  Loads rules from moderation_rules table and caches them in ETS for fast evaluation.
  Rules are refreshed periodically via Oban job.

  Supported rule types:
  - word_filter: Blocks messages containing forbidden words
  - rate_limit: Limits messages per user per time window
  - link_filter: Blocks or flags messages with URLs
  - pattern: Blocks messages matching regex patterns
  """

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

  @type ets_tid :: :ets.tid()

  @type apply_rules_result ::
          message()
          | {:blocked, message(), String.t()}
          | {:flagged, message(), String.t()}

  @rules_snapshot_key :rules_snapshot

  @url_regex ~r/https?:\/\/[^\s]+/

  ### ETS Table Management

  # Start the ETS table for rule caching
  def start_link(_opts) do
    tid = :ets.new(:moderation_rules, [:named_table, :public, read_concurrency: true])
    load_rules_into_cache(tid)
    {:ok, tid}
  end

  def stop(_tid) do
    :ets.delete(:moderation_rules)
    :ok
  end

  ### Rule Loading and Caching

  @spec load_rules_into_cache(ets_tid()) :: :ok
  def load_rules_into_cache(tid) do
    :ets.delete_all_objects(tid)

    active_rules = BeamChat.Moderation.list_active_rules()
    true = :ets.insert(tid, {@rules_snapshot_key, active_rules})

    :ok
  end

  ### Rule Processing

  @doc false
  def ensure_rules_table do
    case :ets.whereis(:moderation_rules) do
      :undefined ->
        _ = start_link([])
        :ets.whereis(:moderation_rules)

      tid ->
        tid
    end
  end

  @doc """
  Reloads rules from the database into the existing ETS table, or creates the table
  if missing. Safe to call while the Broadway pipeline is running (no table delete).
  """
  @spec reload_rules_cache() :: :ok
  def reload_rules_cache do
    case :ets.whereis(:moderation_rules) do
      :undefined ->
        {:ok, _} = start_link([])
        :ok

      tid ->
        load_rules_into_cache(tid)
        :ok
    end
  end

  @spec apply_rules(ets_tid(), message() | map()) :: apply_rules_result()
  def apply_rules(tid, message) do
    rules =
      case :ets.lookup(tid, @rules_snapshot_key) do
        [{@rules_snapshot_key, list}] when is_list(list) -> list
        _ -> []
      end

    # Apply each rule in sequence
    Enum.reduce(rules, message, fn rule, acc_message ->
      case acc_message do
        {:blocked, _msg, _reason} ->
          # Already blocked, keep the block reason
          acc_message

        {:flagged, msg, reason} ->
          merge_flagged_rule_result(apply_single_rule(tid, rule, msg), reason)

        message ->
          # Not yet moderated, apply rule
          apply_single_rule(tid, rule, message)
      end
    end)
  end

  defp merge_flagged_rule_result({:blocked, msg2, reason2}, _prior), do: {:blocked, msg2, reason2}

  defp merge_flagged_rule_result({:flagged, msg2, reason2}, prior),
    do: {:flagged, msg2, prior <> "; " <> reason2}

  defp merge_flagged_rule_result(msg2, prior), do: {:flagged, msg2, prior}

  @spec apply_single_rule(ets_tid(), rule(), message()) ::
          message()
          | {:blocked, message(), String.t()}
          | {:flagged, message(), String.t()}
  def apply_single_rule(
        _tid,
        %{
          type: "word_filter",
          config: %{words: forbidden_words}
        } = _rule,
        %{content: content} = message
      ) do
    # Word filter rule: check for forbidden words
    lower_content = String.downcase(content)

    forbidden_word =
      Enum.find(forbidden_words, fn word ->
        String.contains?(lower_content, String.downcase(word))
      end)

    if forbidden_word do
      {:blocked, message, "Contains forbidden word: #{forbidden_word}"}
    else
      message
    end
  end

  def apply_single_rule(
        _tid,
        %{
          type: "rate_limit",
          config: %{max_count: _max_count, window_seconds: _window_seconds}
        } = _rule,
        %{user_id: _user_id} = message
      ) do
    # Rate limit rule: check if user exceeded message limit
    # In a full implementation, we would use a sliding window counter
    # For MVP, we'll use a simple approach with ETS or could use a dedicated counter
    # For now, we'll allow all messages through (placeholder)
    message
  end

  def apply_single_rule(
        _tid,
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
        _tid,
        %{
          type: "pattern",
          config: %{patterns: patterns}
        } = _rule,
        %{content: content} = message
      ) do
    # Pattern rule: check against regex patterns
    matched_pattern =
      Enum.find(patterns, fn pattern ->
        Regex.match?(pattern, content)
      end)

    if matched_pattern do
      {:blocked, message, "Matches forbidden pattern: #{matched_pattern}"}
    else
      message
    end
  end

  def apply_single_rule(_tid, _rule, message) do
    # Unknown rule type, allow message through
    message
  end

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
