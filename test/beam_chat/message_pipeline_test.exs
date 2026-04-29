defmodule BeamChat.MessagePipelineTest do
  use BeamChat.DataCase, async: true

  import BeamChat.TestFixtures
  import Ecto.Query

  alias BeamChat.MessagePipeline
  alias BeamChat.MessagePipeline.Persister
  alias BeamChat.MessagePipeline.Validator
  alias BeamChat.Messages.Message
  alias BeamChat.Repo

  describe "MessagePipeline" do
    test "pipeline is started with the application" do
      assert is_pid(Process.whereis(MessagePipeline))
    end

    test "validator accepts valid message" do
      valid_message = %{
        room_id: 1,
        user_id: 101,
        content: "Hello world",
        inserted_at: nil
      }

      assert {:ok, _} = Validator.validate(valid_message)
    end

    test "validator rejects invalid message" do
      invalid_message = %{
        # Invalid room ID
        room_id: -1,
        user_id: 101,
        content: "Hello world",
        inserted_at: nil
      }

      assert {:error, _} = Validator.validate(invalid_message)
    end

    test "persister handles empty messages" do
      assert {:ok, []} = Persister.batch_execute([])
    end
  end

  describe "Broadway integration" do
    @describetag :capture_log

    test "test_message/3 runs validate → persist and returns ack with sandbox metadata" do
      owner = user_fixture()
      cat = room_category_fixture()
      room = room_fixture(owner, %{category_id: cat.id})
      sender = user_fixture()

      data = %{
        room_id: room.id,
        user_id: sender.id,
        content: "broadway integration",
        inserted_at: nil
      }

      assert {:ok, _} = Validator.validate(data)

      ref =
        Broadway.test_message(MessagePipeline, data, metadata: %{ecto_sandbox: self()})

      assert_receive {:ack, ^ref, successful, failed}, 3000
      assert failed == []
      assert length(successful) == 1

      count =
        Repo.aggregate(
          from(m in Message,
            where: m.room_id == ^room.id and m.content == "broadway integration"
          ),
          :count
        )

      assert count == 1
    end
  end
end
