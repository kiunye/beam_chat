defmodule BeamChat.DirectTest do
  use BeamChat.DataCase, async: true

  import BeamChat.TestFixtures

  alias BeamChat.Direct

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
end
