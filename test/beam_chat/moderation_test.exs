defmodule BeamChat.ModerationTest do
  @moduledoc """
  Moderation context and rule engine (PRD §2.5): rule application for
  word/link/pattern rules, and the load-bearing logging contract — every
  block or flag from a send path writes a moderation_logs entry as part
  of the same operation.

  The `BeamChat.Moderation.RuleEngine` GenServer already runs under the
  application tree and owns the global `:moderation_rules` ETS table;
  `load_moderation_rules/1` registers rules and refreshes that cache.
  These tests are async: false so the refresh's database query runs on
  the test's shared sandbox connection.
  """

  use BeamChat.DataCase, async: false

  # The shared room_fixture creates rooms without a slug, which the room
  # changeset currently rejects (see the defect note below). Re-import
  # TestFixtures without it so the local slug-aware version can use the
  # same name.
  import BeamChat.TestFixtures, except: [room_fixture: 1, room_fixture: 2]

  alias BeamChat.Direct
  alias BeamChat.Direct.DirectMessage
  alias BeamChat.Messages.Message
  alias BeamChat.Moderation
  alias BeamChat.Moderation.ModerationLog
  alias BeamChat.Moderation.RuleEngine
  alias BeamChat.Rooms

  # DEFECT WORKAROUND (lib, reported in the test run summary):
  # Rooms.Room.changeset/2 runs validate_required(:slug) before put_slug/1
  # derives one from the name, so the shared room_fixture — which creates
  # rooms without a slug — fails. Shadow it locally with an explicit slug.
  defp room_fixture(owner, attrs \\ []) do
    attrs = Map.new(attrs)
    slug = Map.get_lazy(attrs, :slug, fn -> "room-#{System.unique_integer([:positive])}" end)
    BeamChat.TestFixtures.room_fixture(owner, Map.put(attrs, :slug, slug))
  end

  setup do
    # Registration fixtures hash passwords with bcrypt; keep the suite fast.
    Application.put_env(:bcrypt_elixir, :log_rounds, 1)

    on_exit(fn -> Application.delete_env(:bcrypt_elixir, :log_rounds) end)

    :ok
  end

  describe "RuleEngine.apply_rules/1" do
    test "a word_filter rule blocks matching content and carries the rule's provenance" do
      [rule] =
        load_moderation_rules([
          %{
            name: "word filter #{System.unique_integer([:positive])}",
            type: "word_filter",
            config: %{"words" => ["bannedword"]}
          }
        ])

      message = %{
        room_id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate(),
        content: "hello bannedword world"
      }

      assert {:blocked, ^message, returned_rule, reason} = RuleEngine.apply_rules(message)
      assert returned_rule.id == rule.id
      assert reason =~ "bannedword"
    end

    test "a link_filter rule blocks forbidden domains" do
      [rule] =
        load_moderation_rules([
          %{
            name: "link block #{System.unique_integer([:positive])}",
            type: "link_filter",
            config: %{"action" => "block", "domains" => ["spam.example"]}
          }
        ])

      message = %{
        room_id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate(),
        content: "check https://spam.example/x for free stuff"
      }

      assert {:blocked, _msg, returned_rule, reason} = RuleEngine.apply_rules(message)
      assert returned_rule.id == rule.id
      assert reason =~ "https://spam.example/x"
    end

    test "a link_filter rule flags instead of blocking when configured to" do
      [rule] =
        load_moderation_rules([
          %{
            name: "link flag #{System.unique_integer([:positive])}",
            type: "link_filter",
            config: %{"action" => "flag", "domains" => ["spam.example"]}
          }
        ])

      message = %{
        room_id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate(),
        content: "look at https://spam.example/x please"
      }

      assert {:flagged, _msg, returned_rule, reason} = RuleEngine.apply_rules(message)
      assert returned_rule.id == rule.id
      assert reason =~ "Contains link"
    end

    test "a pattern rule blocks matching regexes" do
      [rule] =
        load_moderation_rules([
          %{
            name: "pattern #{System.unique_integer([:positive])}",
            type: "pattern",
            config: %{"patterns" => ["shady\\d+deal"]}
          }
        ])

      message = %{
        room_id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate(),
        content: "wow shady42deal"
      }

      assert {:blocked, _msg, returned_rule, reason} = RuleEngine.apply_rules(message)
      assert returned_rule.id == rule.id
      assert reason =~ Regex.source(~r{shady\d+deal})
    end

    test "messages pass through unchanged when no rule matches" do
      load_moderation_rules([])

      message = %{
        room_id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate(),
        content: "perfectly fine"
      }

      assert ^message = RuleEngine.apply_rules(message)
    end
  end

  # The pipeline logging contract (PRD §2.5): a block or flag and its log
  # entry are one operation — the block is reported to the sender AND the
  # trail is written; a flagged message persists with its flag AND the log
  # commits with the row.
  describe "the send-path logging contract (PRD §2.5)" do
    test "a blocked room message is rejected, logged, and never persisted" do
      owner = user_fixture()
      room = room_fixture(owner)

      [rule] =
        load_moderation_rules([
          %{
            name: "word filter #{System.unique_integer([:positive])}",
            type: "word_filter",
            config: %{"words" => ["bannedword"]}
          }
        ])

      content = "hello bannedword world"

      assert {:error, {:blocked, reason}} = Rooms.send_message(room, owner.id, content)
      assert reason =~ "bannedword"

      # no message row was written
      refute Repo.exists?(from m in Message, where: m.room_id == ^room.id)

      log = Repo.one(from l in ModerationLog, where: l.action == "message_blocked")

      refute is_nil(log)
      assert log.target_type == "room"
      assert log.target_id == room.id
      assert log.rule_id == rule.id
      assert is_nil(log.actor_id)
      assert log.metadata["sender_id"] == owner.id
      assert log.metadata["kind"] == "room"
      assert log.metadata["rule_name"] == rule.name
      assert log.metadata["content_preview"] == content
    end

    test "a flagged room message persists with its flag and is logged in the same operation" do
      owner = user_fixture()
      room = room_fixture(owner)

      [rule] =
        load_moderation_rules([
          %{
            name: "link flag #{System.unique_integer([:positive])}",
            type: "link_filter",
            config: %{"action" => "flag", "domains" => ["spam.example"]}
          }
        ])

      assert {:ok, %Message{} = message} =
               Rooms.send_message(room, owner.id, "look at https://spam.example/x")

      assert message.moderation_flag =~ "Contains link"

      # the flagged row really is persisted
      persisted = Repo.get_by(Message, id: message.id)
      assert persisted.moderation_flag == message.moderation_flag

      log = Repo.one(from l in ModerationLog, where: l.action == "message_flagged")

      refute is_nil(log)
      assert log.target_type == "message"
      assert log.target_id == message.id
      assert log.rule_id == rule.id
      assert log.metadata["sender_id"] == owner.id
      assert log.metadata["kind"] == "room"
    end

    test "a blocked DM is rejected against the conversation and logged" do
      alice = user_fixture()
      bob = user_fixture()
      conversation = conversation_fixture(alice, bob)

      [rule] =
        load_moderation_rules([
          %{
            name: "word filter #{System.unique_integer([:positive])}",
            type: "word_filter",
            config: %{"words" => ["bannedword"]}
          }
        ])

      assert {:error, {:blocked, reason}} =
               Direct.send_message(conversation.id, alice.id, "psst bannedword")

      assert reason =~ "bannedword"

      # nothing was persisted to the conversation
      refute Repo.exists?(from m in DirectMessage, where: m.conversation_id == ^conversation.id)

      log = Repo.one(from l in ModerationLog, where: l.action == "message_blocked")

      refute is_nil(log)
      assert log.target_type == "conversation"
      assert log.target_id == conversation.id
      assert log.rule_id == rule.id
      assert log.metadata["sender_id"] == alice.id
      assert log.metadata["kind"] == "direct"
    end

    test "a flagged DM persists with its flag and is logged against the message" do
      alice = user_fixture()
      bob = user_fixture()
      conversation = conversation_fixture(alice, bob)

      [rule] =
        load_moderation_rules([
          %{
            name: "link flag #{System.unique_integer([:positive])}",
            type: "link_filter",
            config: %{"action" => "flag", "domains" => ["spam.example"]}
          }
        ])

      assert {:ok, %DirectMessage{} = message} =
               Direct.send_message(conversation.id, alice.id, "see https://spam.example/x")

      assert message.moderation_flag =~ "Contains link"

      log = Repo.one(from l in ModerationLog, where: l.action == "message_flagged")

      refute is_nil(log)
      assert log.target_type == "message"
      assert log.target_id == message.id
      assert log.rule_id == rule.id
      assert log.metadata["sender_id"] == alice.id
      assert log.metadata["kind"] == "direct"
    end

    test "a clean room message sends without writing any log rows" do
      owner = user_fixture()
      room = room_fixture(owner)
      load_moderation_rules([])

      logs_before = log_count()

      assert {:ok, %Message{}} = Rooms.send_message(room, owner.id, "a perfectly clean message")

      assert log_count() == logs_before
    end

    test "a clean DM sends without writing any log rows" do
      alice = user_fixture()
      bob = user_fixture()
      conversation = conversation_fixture(alice, bob)
      load_moderation_rules([])

      logs_before = log_count()

      assert {:ok, %DirectMessage{}} =
               Direct.send_message(conversation.id, alice.id, "clean dm content")

      assert log_count() == logs_before
    end
  end

  describe "moderation_logs writes" do
    test "target_type is constrained to message/user/room/conversation" do
      assert {:error, changeset} =
               Moderation.log_moderation_action(%{
                 target_type: "bogus",
                 target_id: Ecto.UUID.generate(),
                 action: "probe"
               })

      assert_error_message(changeset, :target_type, "is invalid")
    end

    test "list_logs/2 paginates newest-first with a has-more flag" do
      user = user_fixture()

      # Explicit, distinct timestamps keep the ordering deterministic
      # (utc_datetime second precision would otherwise tie).
      base = DateTime.add(DateTime.utc_now() |> DateTime.truncate(:second), -3_600, :second)

      rows =
        for i <- 1..3 do
          %{
            target_type: "user",
            target_id: user.id,
            action: "probe_#{i}",
            metadata: %{},
            inserted_at: DateTime.add(base, i, :second)
          }
        end

      {3, _} = Repo.insert_all(ModerationLog, rows)

      {page1, has_more?} = Moderation.list_logs(2, 0)
      assert Enum.map(page1, & &1.action) == ["probe_3", "probe_2"]
      assert has_more?
      assert Enum.all?(page1, &(&1.target_id == user.id))

      {page2, has_more?} = Moderation.list_logs(2, 2)
      assert Enum.map(page2, & &1.action) == ["probe_1"]
      refute has_more?
    end
  end

  defp log_count do
    Repo.one(from l in ModerationLog, select: count(l.id))
  end

  defp assert_error_message(changeset, field, message) do
    assert Enum.any?(changeset.errors, fn {error_field, {error_message, _details}} ->
             error_field == field and error_message == message
           end),
           "expected an error on #{inspect(field)} with message #{inspect(message)}, got: #{inspect(changeset.errors)}"
  end
end
