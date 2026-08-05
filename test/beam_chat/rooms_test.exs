defmodule BeamChat.RoomsTest do
  use BeamChat.DataCase, async: true

  import BeamChat.TestFixtures
  import Ecto.Query

  alias BeamChat.Messages.Message
  alias BeamChat.Repo
  alias BeamChat.Rooms

  describe "set_typing/3" do
    test "broadcasts :user_typing when is_typing is true" do
      room_id = Ecto.UUID.generate()
      uid = Ecto.UUID.generate()

      Phoenix.PubSub.subscribe(BeamChat.PubSub, "room:#{room_id}")

      assert :ok = Rooms.set_typing(room_id, uid, true)
      assert_receive {:user_typing, %{data: ^uid}}
    end

    test "broadcasts :user_stopped_typing when is_typing is false" do
      room_id = Ecto.UUID.generate()
      uid = Ecto.UUID.generate()

      Phoenix.PubSub.subscribe(BeamChat.PubSub, "room:#{room_id}")

      assert :ok = Rooms.set_typing(room_id, uid, false)
      assert_receive {:user_stopped_typing, %{data: ^uid}}
    end
  end

  describe "send_message/3" do
    test "persists and broadcasts" do
      owner = user_fixture()
      cat = room_category_fixture()
      room = room_fixture(owner, %{category_id: cat.id})
      sender = user_fixture()

      Phoenix.PubSub.subscribe(BeamChat.PubSub, "room:#{room.id}")

      assert {:ok, %Message{}} = Rooms.send_message(room.id, sender.id, "hello room")
      assert_receive {:new_message, %Message{} = msg}
      assert msg.content == "hello room"
      assert msg.room_id == room.id

      count =
        Repo.aggregate(
          from(m in Message, where: m.room_id == ^room.id and m.content == "hello room"),
          :count
        )

      assert count == 1
    end
  end
end

defmodule BeamChat.RoomsModerationTest do
  # async: false — this module mutates the shared :moderation_rules ETS cache
  # via BeamChat.Moderation.refresh_rule_cache/0, so it must not run
  # concurrently with other tests.
  use BeamChat.DataCase, async: false

  import BeamChat.TestFixtures
  import Ecto.Query

  alias BeamChat.Messages.Message
  alias BeamChat.Repo
  alias BeamChat.Rooms

  describe "Rooms.send_message/3 moderation" do
    test "blocks moderated content" do
      owner = user_fixture()
      cat = room_category_fixture()
      room = room_fixture(owner, %{category_id: cat.id})
      sender = user_fixture()

      {:ok, _rule} =
        BeamChat.Moderation.create_rule(%{
          name: "x",
          type: "word_filter",
          config: %{words: ["naughty"]},
          is_active: true
        })

      :ok = BeamChat.Moderation.refresh_rule_cache()

      assert {:error, {:blocked, reason}} =
               Rooms.send_message(room.id, sender.id, "say naughty word")

      assert reason =~ "naughty"

      count = Repo.aggregate(from(m in Message, where: m.room_id == ^room.id), :count)
      assert count == 0
    end

    test "returns :empty_content for blank input" do
      owner = user_fixture()
      cat = room_category_fixture()
      room = room_fixture(owner, %{category_id: cat.id})
      sender = user_fixture()

      assert {:error, :empty_content} = Rooms.send_message(room.id, sender.id, "   ")
    end
  end
end
