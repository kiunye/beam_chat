defmodule BeamChat.Rooms.RoomServer do
  @max_buffer_messages 100

  @moduledoc """
  GenServer managing room state for distributed chat rooms.

  State:
    %{
      room_id: room_id(),
      messages: list(),
      message_count: non_neg_integer(),
      members: map(),
      typing: map(),
      ref: reference()
    }

    Messages are kept in a ring buffer (last #{@max_buffer_messages} messages, newest first).
    Members map: user_id -> %{name: string(), presence: :online | :away}
    Typing map: user_id -> timestamp
  """

  use GenServer

  # State type
  @type room_id :: Ecto.UUID.t()
  @type user_id :: Ecto.UUID.t()
  @type message :: %{
          id: non_neg_integer,
          user_id: user_id,
          content: String.t(),
          inserted_at: DateTime.t()
        }
  @type state :: %{
          room_id: room_id,
          messages: list(message),
          message_count: non_neg_integer(),
          members: map(),
          typing: map(),
          ref: reference
        }

  ## Public API

  @spec start_link(room_id :: room_id()) :: {:ok, pid()} | {:error, term()}
  def start_link(room_id) do
    GenServer.start_link(__MODULE__, room_id, name: via_tuple(room_id))
  end

  @spec stop(room_id :: room_id()) :: :ok | {:error, term()}
  def stop(room_id) do
    GenServer.stop(via_tuple(room_id), :normal, 5000)
  end

  @spec join_room(room_id :: room_id(), user_id :: user_id(), user_name :: String.t()) :: :ok
  def join_room(room_id, user_id, user_name) do
    GenServer.cast(via_tuple(room_id), {:join, user_id, user_name})
  end

  @spec leave_room(room_id :: room_id(), user_id :: user_id()) :: :ok
  def leave_room(room_id, user_id) do
    GenServer.cast(via_tuple(room_id), {:leave, user_id})
  end

  @spec send_message(room_id :: room_id(), user_id :: user_id(), content :: String.t()) :: :ok
  def send_message(room_id, user_id, content) do
    GenServer.cast(via_tuple(room_id), {:send_message, user_id, content})
  end

  @spec set_typing(room_id :: room_id(), user_id :: user_id(), is_typing :: boolean()) :: :ok
  def set_typing(room_id, user_id, is_typing) do
    if is_typing do
      GenServer.cast(via_tuple(room_id), {:set_typing, user_id})
    else
      GenServer.cast(via_tuple(room_id), {:clear_typing, user_id})
    end
  end

  @spec get_state(room_id :: room_id()) :: {:ok, state} | {:error, :not_found}
  def get_state(room_id) do
    GenServer.call(via_tuple(room_id), :get_state, 5000)
  end

  ## GenServer Callbacks

  @impl true
  def init(room_id) do
    ref = make_ref()

    state = %{
      room_id: room_id,
      messages: [],
      message_count: 0,
      members: %{},
      typing: %{},
      ref: ref
    }

    # Set up idle shutdown check - 10 minutes
    Process.send_after(self(), :check_idle, 10 * 60 * 1000)

    {:ok, state}
  end

  @impl true
  def handle_cast({:join, user_id, user_name}, state) do
    new_members = Map.put(state.members, user_id, %{name: user_name, presence: :online})
    new_state = %{state | members: new_members}

    # Broadcast member update
    broadcast_room_update(new_state, :member_joined, user_id)

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:leave, user_id}, state) do
    new_members = Map.delete(state.members, user_id)
    new_typing = Map.delete(state.typing, user_id)
    new_state = %{state | members: new_members, typing: new_typing}

    # Broadcast member update
    broadcast_room_update(new_state, :member_left, user_id)

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:send_message, user_id, content}, state) do
    message = %{
      id: System.unique_integer([:positive]),
      user_id: user_id,
      content: content,
      inserted_at: DateTime.utc_now()
    }

    {new_messages, new_count} = push_ring_buffer(state.messages, state.message_count, message)

    new_state = %{state | messages: new_messages, message_count: new_count}

    # Broadcast new message
    broadcast_room_update(new_state, :new_message, message)

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:set_typing, user_id}, state) do
    now = System.system_time(:millisecond)
    clear_after_ms = 2200

    case Map.get(state.typing, user_id) do
      nil ->
        new_typing = Map.put(state.typing, user_id, now)
        new_state = %{state | typing: new_typing}

        # First time we see this user typing; broadcast.
        broadcast_room_update(new_state, :user_typing, user_id)
        {:noreply, new_state}

      last_ts when now - last_ts > clear_after_ms ->
        new_typing = Map.put(state.typing, user_id, now)
        new_state = %{state | typing: new_typing}

        # Typing was considered cleared; broadcast again.
        broadcast_room_update(new_state, :user_typing, user_id)
        {:noreply, new_state}

      _last_ts ->
        # User is still typing within the clear window. Avoid redundant broadcasts,
        # but refresh the timestamp to extend the typing session on the server.
        new_state = %{state | typing: Map.put(state.typing, user_id, now)}
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_cast({:clear_typing, user_id}, state) do
    if Map.has_key?(state.typing, user_id) do
      new_typing = Map.delete(state.typing, user_id)
      new_state = %{state | typing: new_typing}

      # Only broadcast when it was actually typing.
      broadcast_room_update(new_state, :user_stopped_typing, user_id)

      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, {:ok, state}, state}
  end

  @impl true
  def handle_info(:check_idle, state) do
    # Check if room has been idle for 10 minutes with zero members
    if map_size(state.members) == 0 do
      # Room is idle, shut down
      {:stop, :normal, state}
    else
      # Reset timer for another 10 minutes
      Process.send_after(self(), :check_idle, 10 * 60 * 1000)
      {:noreply, state}
    end
  end

  ## Helper Functions

  defp via_tuple(room_id) do
    {:via, Horde.Registry, {BeamChat.Registry, {:room, room_id}}}
  end

  # Newest-first list; cap at @max_buffer_messages without building a list longer than max.
  defp push_ring_buffer(messages, count, msg) when count < @max_buffer_messages do
    {[msg | messages], count + 1}
  end

  defp push_ring_buffer(messages, _count, msg) do
    {[msg | Enum.take(messages, @max_buffer_messages - 1)], @max_buffer_messages}
  end

  defp broadcast_room_update(state, event_type, data) do
    message = {
      event_type,
      %{
        room_id: state.room_id,
        data: data,
        timestamp: System.system_time(:millisecond)
      }
    }

    Phoenix.PubSub.broadcast(BeamChat.PubSub, "room:#{state.room_id}", message)
  end
end
