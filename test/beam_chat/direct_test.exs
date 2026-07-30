defmodule BeamChat.DirectTest do
  use BeamChat.DataCase, async: true

  import BeamChat.TestFixtures
  import Ecto.Query

  alias BeamChat.Direct
  alias BeamChat.Direct.DirectMessage
  alias BeamChat.MessagePipeline
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
    test "rejects blank content without touching Broadway" do
      u1 = user_fixture()
      u2 = user_fixture()
      conv = conversation_fixture(u1, u2)

      assert {:error, :empty_content} = Direct.send_message(conv.id, u1.id, "   ")
    end

    test "enqueues a DM into the Broadway pipeline and the row appears in direct_messages" do
      u1 = user_fixture()
      u2 = user_fixture()
      conv = conversation_fixture(u1, u2)

      # Push directly through the pipeline so the message carries the
      # Ecto sandbox metadata for the Broadway processor workers. (See
      # `BeamChat.BroadwayEctoSandbox`.) Going through `Direct.send_message/3`
      # from inside a test would produce a DM that bypasses the test sandbox
      # and leaks into the shared DB — so we exercise that code path via
      # the lower-level entry point here, and exercise the public API in the
      # next test.
      ref =
        Broadway.test_message(
          MessagePipeline,
          %{
            kind: :direct,
            conversation_id: conv.id,
            user_id: u1.id,
            content: "pipeline dm"
          },
          metadata: %{ecto_sandbox: self()}
        )

      assert_receive {:ack, ^ref, successful, failed}, 3000
      assert failed == []
      assert length(successful) == 1

      count =
        Repo.aggregate(
          from(m in DirectMessage,
            where: m.conversation_id == ^conv.id and m.content == "pipeline dm"
          ),
          :count
        )

      assert count == 1
    end

    test "Direct.send_message/3 enqueues to Broadway and returns :ok" do
      u1 = user_fixture()
      u2 = user_fixture()
      conv = conversation_fixture(u1, u2)

      # The synchronous API must return :ok for valid input. We don't wait
      # for the row to land — that would race the test sandbox — but the
      # contract that callers depend on (LiveView) is the `:ok` return.
      assert :ok = Direct.send_message(conv.id, u1.id, "ok enqueue")
    end

    test "broadcasts a {:new_direct_message, ...} event after persistence" do
      u1 = user_fixture()
      u2 = user_fixture()
      conv = conversation_fixture(u1, u2)
      Direct.subscribe(conv.id)

      ref =
        Broadway.test_message(
          MessagePipeline,
          %{
            kind: :direct,
            conversation_id: conv.id,
            user_id: u1.id,
            content: "broadcast check"
          },
          metadata: %{ecto_sandbox: self()}
        )

      assert_receive {:ack, ^ref, _successful, _failed}, 3000
      assert_receive {:new_direct_message, %DirectMessage{} = msg}, 3000
      assert msg.content == "broadcast check"
      assert msg.conversation_id == conv.id
    end
  end
end
