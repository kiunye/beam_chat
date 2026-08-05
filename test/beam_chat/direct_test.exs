defmodule BeamChat.DirectTest do
  use BeamChat.DataCase, async: true

  import BeamChat.TestFixtures
  import Ecto.Query

  alias BeamChat.Direct
  alias BeamChat.Direct.DirectMessage
  alias BeamChat.Repo

  describe "list_conversations_for/2" do
    test "returns pagination metadata and rows" do
      u = user_fixture()
      others = for _ <- 1..7, do: user_fixture()
      for other <- others, do: conversation_fixture(u, other)

      result = Direct.list_conversations_for(u, %{page: 1, limit: 5})

      assert result.total_count == 7
      assert result.page == 1
      assert result.limit == 5
      assert result.page_count == 2
      assert length(result.rows) == 5
    end

    test "second page returns remaining conversations" do
      u = user_fixture()
      others = for _ <- 1..7, do: user_fixture()
      for other <- others, do: conversation_fixture(u, other)

      result = Direct.list_conversations_for(u, %{page: 2, limit: 5})

      assert result.page == 2
      assert length(result.rows) == 2
    end

    test "loads other user and last message per row" do
      u1 = user_fixture()
      u2 = user_fixture()
      conv = conversation_fixture(u1, u2)
      direct_message_fixture(conv, u2, %{content: "last line"})

      assert %{rows: [{c, other, last}]} = Direct.list_conversations_for(u1)
      assert c.id == conv.id
      assert other.id == u2.id
      assert last.content == "last line"
    end
  end

  describe "send_message/3" do
    test "rejects blank content" do
      u1 = user_fixture()
      u2 = user_fixture()
      conv = conversation_fixture(u1, u2)

      assert {:error, :empty_content} = Direct.send_message(conv.id, u1.id, "   ")
    end

    test "persists a DM synchronously and returns {:ok, %DirectMessage{}}" do
      u1 = user_fixture()
      u2 = user_fixture()
      conv = conversation_fixture(u1, u2)

      assert {:ok, %DirectMessage{}} = Direct.send_message(conv.id, u1.id, "hello")

      count =
        Repo.aggregate(
          from(m in DirectMessage,
            where: m.conversation_id == ^conv.id and m.content == "hello"
          ),
          :count
        )

      assert count == 1
    end

    test "returns {:ok, %DirectMessage{}} and the row is persisted" do
      u1 = user_fixture()
      u2 = user_fixture()
      conv = conversation_fixture(u1, u2)

      assert {:ok, %DirectMessage{} = msg} = Direct.send_message(conv.id, u1.id, "ok enqueue")
      assert msg.content == "ok enqueue"
      assert msg.conversation_id == conv.id

      count =
        Repo.aggregate(
          from(m in DirectMessage,
            where: m.conversation_id == ^conv.id and m.content == "ok enqueue"
          ),
          :count
        )

      assert count == 1
    end

    test "broadcasts a {:new_direct_message, ...} event after persistence" do
      u1 = user_fixture()
      u2 = user_fixture()
      conv = conversation_fixture(u1, u2)
      Direct.subscribe(conv.id)

      assert {:ok, %DirectMessage{}} = Direct.send_message(conv.id, u1.id, "broadcast check")
      assert_receive {:new_direct_message, %DirectMessage{} = msg}, 1000
      assert msg.content == "broadcast check"
      assert msg.conversation_id == conv.id
    end
  end
end
