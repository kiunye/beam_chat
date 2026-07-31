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

    test "exposes a members/typing-only state shape (no message ring buffer)" do
      # P1 #8 — the room server no longer owns a messages ring buffer.
      # Persistence + broadcast flow through BeamChat.MessagePipeline.
      room_id = Ecto.UUID.generate()
      {:ok, _pid} = RoomServer.start_link(room_id)

      {:ok, state} = RoomServer.get_state(room_id)

      assert Map.has_key?(state, :members)
      assert Map.has_key?(state, :typing)
      refute Map.has_key?(state, :messages)
      refute Map.has_key?(state, :message_count)
    end
  end
end
