defmodule BeamChat.Rooms.RoomServerTest do
  use BeamChat.DataCase, async: true

  alias BeamChat.Rooms.RoomServer

  describe "RoomServer" do
    test "starts and stops successfully" do
      room_id = Ecto.UUID.generate()
      {:ok, pid} = RoomServer.start_link(room_id)
      assert is_pid(pid)

      :ok = RoomServer.stop(room_id)
    end

    test "handles user join and leave" do
      room_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()
      {:ok, _pid} = RoomServer.start_link(room_id)

      RoomServer.join_room(room_id, user_id, "Alice")
      {:ok, state} = RoomServer.get_state(room_id)
      assert state.members == %{user_id => %{name: "Alice", presence: :online}}

      RoomServer.leave_room(room_id, user_id)
      {:ok, state} = RoomServer.get_state(room_id)
      assert state.members == %{}
    end

    test "handles message sending" do
      room_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()
      {:ok, _pid} = RoomServer.start_link(room_id)

      RoomServer.join_room(room_id, user_id, "Bob")
      RoomServer.send_message(room_id, user_id, "Hello world")

      {:ok, state} = RoomServer.get_state(room_id)
      assert length(state.messages) == 1
      assert Enum.at(state.messages, 0).user_id == user_id
      assert Enum.at(state.messages, 0).content == "Hello world"
    end

    test "handles typing indicators" do
      room_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()
      {:ok, _pid} = RoomServer.start_link(room_id)

      RoomServer.join_room(room_id, user_id, "Charlie")
      RoomServer.set_typing(room_id, user_id, true)

      {:ok, state} = RoomServer.get_state(room_id)
      assert Map.has_key?(state.typing, user_id)

      RoomServer.set_typing(room_id, user_id, false)
      {:ok, state} = RoomServer.get_state(room_id)
      assert not Map.has_key?(state.typing, user_id)
    end

    test "maintains message ring buffer (last 100 messages)" do
      room_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()
      {:ok, _pid} = RoomServer.start_link(room_id)

      RoomServer.join_room(room_id, user_id, "David")

      for i <- 1..150 do
        RoomServer.send_message(room_id, user_id, "Message #{i}")
      end

      {:ok, state} = RoomServer.get_state(room_id)
      assert length(state.messages) == 100
      assert state.message_count == 100
      assert Enum.at(state.messages, 0).content == "Message 150"
      assert Enum.at(state.messages, -1).content == "Message 51"
    end
  end
end
