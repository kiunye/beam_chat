defmodule BeamChat.MessagesTest do
  @moduledoc """
  The message pipeline's three stages: `Validator` (structure and
  content rules), `Persister` (ordered batch writes for room and direct
  rows), and `Pipeline.run/1` (moderation + persist + same-operation
  logging).

  The rule-engine tests here refresh the global ETS cache, so these
  tests are async: false to run on the shared sandbox connection.
  """

  use BeamChat.DataCase, async: false

  # The shared room_fixture creates rooms without a slug, which the room
  # changeset currently rejects (see the defect note below). Re-import
  # TestFixtures without it so the local slug-aware version can use the
  # same name.
  import BeamChat.TestFixtures, except: [room_fixture: 1, room_fixture: 2]

  alias BeamChat.Direct.DirectMessage
  alias BeamChat.Messages.Message
  alias BeamChat.Messages.Persister
  alias BeamChat.Messages.Pipeline
  alias BeamChat.Messages.Validator
  alias BeamChat.Moderation.ModerationLog

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

  describe "Validator.validate/1" do
    test "a room message with valid ids and content passes, trimmed" do
      message = %{
        kind: :room,
        room_id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate(),
        content: "  padded content  "
      }

      assert {:ok, validated} = Validator.validate(message)
      assert validated.content == "padded content"
      assert validated.room_id == message.room_id
      assert validated.user_id == message.user_id
    end

    test "kind defaults to :room when absent" do
      message = %{
        room_id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate(),
        content: "implicit kind"
      }

      assert {:ok, validated} = Validator.validate(message)
      assert validated.content == "implicit kind"
    end

    test ":room requires a room_id and a user_id" do
      user_id = Ecto.UUID.generate()

      assert {:error, :invalid_message_structure} =
               Validator.validate(%{kind: :room, user_id: user_id, content: "no room"})

      assert {:error, :invalid_message_structure} =
               Validator.validate(%{
                 kind: :room,
                 room_id: Ecto.UUID.generate(),
                 content: "no user"
               })
    end

    test ":room rejects malformed ids" do
      assert {:error, :invalid_message_structure} =
               Validator.validate(%{
                 kind: :room,
                 room_id: "not-a-uuid",
                 user_id: Ecto.UUID.generate(),
                 content: "bad room id"
               })

      assert {:error, :invalid_message_structure} =
               Validator.validate(%{
                 kind: :room,
                 room_id: Ecto.UUID.generate(),
                 user_id: 0,
                 content: "bad user id"
               })
    end

    test "a direct message requires a conversation_id" do
      assert {:ok, validated} =
               Validator.validate(%{
                 kind: :direct,
                 conversation_id: Ecto.UUID.generate(),
                 user_id: Ecto.UUID.generate(),
                 content: "dm body"
               })

      assert validated.content == "dm body"
      assert validated.kind == :direct

      assert {:error, :invalid_message_structure} =
               Validator.validate(%{
                 kind: :direct,
                 user_id: Ecto.UUID.generate(),
                 content: "no conversation"
               })
    end

    test "content is bounded to 1..10_000 bytes" do
      room_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()

      assert {:ok, _} =
               Validator.validate(%{
                 kind: :room,
                 room_id: room_id,
                 user_id: user_id,
                 content: String.duplicate("a", 10_000)
               })

      assert {:error, :invalid_message_length} =
               Validator.validate(%{
                 kind: :room,
                 room_id: room_id,
                 user_id: user_id,
                 content: String.duplicate("a", 10_001)
               })
    end

    test "empty content is rejected" do
      assert {:error, :invalid_message_structure} =
               Validator.validate(%{
                 kind: :room,
                 room_id: Ecto.UUID.generate(),
                 user_id: Ecto.UUID.generate(),
                 content: ""
               })
    end

    test "whitespace-only content is trimmed to an empty string (documented behavior)" do
      # The size guard runs before trimming, so "   " passes the structure
      # stage and is then trimmed. Downstream send paths pre-trim (Direct)
      # or rely on this quirk (Rooms); documented here as-implemented.
      assert {:ok, validated} =
               Validator.validate(%{
                 kind: :room,
                 room_id: Ecto.UUID.generate(),
                 user_id: Ecto.UUID.generate(),
                 content: "   "
               })

      assert validated.content == ""
    end

    test "non-binary content is rejected" do
      assert {:error, :invalid_message_structure} =
               Validator.validate(%{
                 kind: :room,
                 room_id: Ecto.UUID.generate(),
                 user_id: Ecto.UUID.generate(),
                 content: nil
               })
    end
  end

  describe "Persister.persist_ordered/1" do
    test "writes a mixed room+direct batch and returns results in input order" do
      owner = user_fixture()
      room = room_fixture(owner)
      alice = user_fixture()
      bob = user_fixture()
      conversation = conversation_fixture(alice, bob)

      batch = [
        %{kind: :room, room_id: room.id, user_id: owner.id, content: "room one"},
        %{kind: :direct, conversation_id: conversation.id, user_id: alice.id, content: "dm one"},
        %{kind: :room, room_id: room.id, user_id: owner.id, content: "room two"}
      ]

      assert [
               {:ok, %Message{} = first},
               {:ok, %DirectMessage{} = dm},
               {:ok, %Message{} = second}
             ] = Persister.persist_ordered(batch)

      assert first.content == "room one"
      assert second.content == "room two"
      assert dm.content == "dm one"
      assert first.id != second.id

      room_rows = Repo.one(from m in Message, where: m.room_id == ^room.id, select: count(m.id))

      dm_rows =
        Repo.one(
          from m in DirectMessage,
            where: m.conversation_id == ^conversation.id,
            select: count(m.id)
        )

      assert room_rows == 2
      assert dm_rows == 1
    end

    test "falls back to per-row handling for invalid shapes" do
      owner = user_fixture()
      room = room_fixture(owner)

      results =
        Persister.persist_ordered([
          %{kind: :room, room_id: room.id, user_id: owner.id, content: "valid row"},
          %{totally: :bogus}
        ])

      assert [{:ok, %Message{}}, {:error, :invalid_message_shape}] = results
    end

    test "an empty batch writes nothing" do
      assert [] = Persister.persist_ordered([])
    end
  end

  describe "Persister.persist_and_preload/1" do
    test "persists and preloads the sender" do
      user = user_fixture()
      room = room_fixture(user)

      assert {:ok, %Message{} = row} =
               Persister.persist_and_preload(%{
                 kind: :room,
                 room_id: room.id,
                 user_id: user.id,
                 content: "preloaded sender"
               })

      assert row.content == "preloaded sender"
      assert row.sender.id == user.id
      assert row.sender.username == user.username
    end
  end

  describe "Pipeline.run/1" do
    setup do
      owner = user_fixture()
      room = room_fixture(owner)

      %{owner: owner, room: room}
    end

    test "a clean message persists through the persister", %{owner: owner, room: room} do
      load_moderation_rules([])

      logs_before = Repo.one(from l in ModerationLog, select: count(l.id))

      assert {:ok, %Message{} = row} =
               Pipeline.run(%{
                 kind: :room,
                 room_id: room.id,
                 user_id: owner.id,
                 content: "clean unit content"
               })

      assert row.content == "clean unit content"
      assert is_nil(row.moderation_flag)
      assert Repo.get_by(Message, id: row.id)

      assert Repo.one(from l in ModerationLog, select: count(l.id)) == logs_before
    end

    test "a blocked message fails and writes the log as part of the send", %{
      owner: owner,
      room: room
    } do
      [rule] =
        load_moderation_rules([
          %{
            name: "word filter #{System.unique_integer([:positive])}",
            type: "word_filter",
            config: %{"words" => ["bannedword"]}
          }
        ])

      assert {:error, {:blocked, reason}} =
               Pipeline.run(%{
                 kind: :room,
                 room_id: room.id,
                 user_id: owner.id,
                 content: "unit blocked bannedword"
               })

      assert reason =~ "bannedword"
      refute Repo.exists?(from m in Message, where: m.room_id == ^room.id)

      log = Repo.one(from l in ModerationLog, where: l.action == "message_blocked")

      refute is_nil(log)
      assert log.target_type == "room"
      assert log.target_id == room.id
      assert log.rule_id == rule.id
      assert log.metadata["sender_id"] == owner.id
    end

    test "a flagged message persists with its flag and its log row in one operation", %{
      owner: owner,
      room: room
    } do
      [rule] =
        load_moderation_rules([
          %{
            name: "link flag #{System.unique_integer([:positive])}",
            type: "link_filter",
            config: %{"action" => "flag", "domains" => ["spam.example"]}
          }
        ])

      assert {:ok, %Message{} = row} =
               Pipeline.run(%{
                 kind: :room,
                 room_id: room.id,
                 user_id: owner.id,
                 content: "unit flagged https://spam.example/x"
               })

      assert row.moderation_flag =~ "Contains link"

      log = Repo.one(from l in ModerationLog, where: l.action == "message_flagged")

      refute is_nil(log)
      assert log.target_type == "message"
      assert log.target_id == row.id
      assert log.rule_id == rule.id
    end
  end
end
