defmodule BeamChat.MessagesTest do
  use BeamChat.DataCase, async: true

  alias BeamChat.Messages.Persister
  alias BeamChat.Messages.Validator

  describe "Validator" do
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
  end

  describe "Persister" do
    test "persister handles empty messages" do
      assert {:ok, []} = Persister.batch_execute([])
    end
  end
end
