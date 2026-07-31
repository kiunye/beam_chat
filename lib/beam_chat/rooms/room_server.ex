defmodule BeamChat.Rooms.RoomServer do
  @moduledoc """
  GenServer managing room-level ephemeral state for distributed chat rooms.

  Owns:

    - `members` — user_id → %{name, presence, last_seen} for join/leave
      accounting, with bounded lifetime (see below).
    - `typing`  — user_id → timestamp for typing-indicator broadcasts.
    - `idle shutdown` — 10-minute timer that stops the GenServer when the
      room has no members.

  The room server does **not** own messages. Message persistence and
  broadcast go through `BeamChat.MessagePipeline` (Broadway) +
  `BeamChat.MessagePipeline.Broadcaster`, which guarantees moderation,
  persistence ordering, and the canonical `room:<room_id>` PubSub topic.

  Presence: `BeamChatWeb.RoomPresence` (Phoenix.Presence) is the canonical
  source of truth for the online user list. The `members` map here is a
  bounded cache: stale entries (no join/typing activity for 5 minutes) are
  evicted by a periodic sweep, since LiveView `terminate/2` is not guaranteed
  to run on browser crashes. See SECURITY_REVIEW.md P2 #15, P2 #18.

  See SECURITY_REVIEW.md P1 #8.

  State shape:

      %{
        room_id: room_id(),
        members: map(),
        typing:  map(),
        ref:     reference()
      }

  Members map: `user_id -> %{name: string(), presence: :online | :away, last_seen: integer()}`
  Typing map:  `user_id -> timestamp`
  """

  use GenServer

  # State type
  @type room_id :: Ecto.UUID.t()
  @type user_id :: Ecto.UUID.t()
  @type state :: %{
          room_id: room_id,
          members: map(),
          typing: map(),
          ref: reference
        }

  # Evict members with no join/typing activity in this window. LiveView
  # terminate/2 is best-effort, so without this a crashed client would
  # otherwise leave a ghost entry forever. Tunable at runtime so tests can
  # shrink the window.
  @default_stale_member_after_ms 5 * 60 * 1000
  @default_sweep_interval_ms 60 * 1000

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
      members: %{},
      typing: %{},
      ref: ref
    }

    # Set up idle shutdown check - 10 minutes
    Process.send_after(self(), :check_idle, 10 * 60 * 1000)

    # Set up stale-member sweep
    Process.send_after(self(), :sweep_stale_members, sweep_interval_ms())

    {:ok, state}
  end

  @impl true
  def handle_cast({:join, user_id, user_name}, state) do
    now = System.system_time(:millisecond)

    new_members =
      Map.put(state.members, user_id, %{
        name: user_name,
        presence: :online,
        last_seen: now
      })

    new_state = %{state | members: new_members}

    # Broadcast member update
    broadcast_room_update(new_state, :member_joined, user_id)

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:leave, user_id}, state) do
    # Same cleanup path as the stale-member sweep: drop the member and any
    # typing entry, then broadcast :member_left.
    {:noreply, evict_member(state, user_id)}
  end

  @impl true
  def handle_cast({:set_typing, user_id}, state) do
    now = System.system_time(:millisecond)
    clear_after_ms = 2200

    # Typing counts as activity for the stale-member sweep.
    state = touch_member(state, user_id, now)

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

  @impl true
  def handle_info(:sweep_stale_members, state) do
    now = System.system_time(:millisecond)

    stale =
      Enum.filter(state.members, fn {_user_id, %{last_seen: last_seen}} ->
        now - last_seen >= stale_member_after_ms()
      end)

    new_state =
      Enum.reduce(stale, state, fn {user_id, _entry}, acc ->
        evict_member(acc, user_id)
      end)

    # Re-arm the sweep regardless; idle shutdown stays on its own 10-min timer.
    Process.send_after(self(), :sweep_stale_members, sweep_interval_ms())

    {:noreply, new_state}
  end

  ## Helper Functions

  defp stale_member_after_ms do
    Application.get_env(:beam_chat, :room_member_stale_after_ms, @default_stale_member_after_ms)
  end

  defp sweep_interval_ms do
    Application.get_env(:beam_chat, :room_member_sweep_interval_ms, @default_sweep_interval_ms)
  end

  defp touch_member(state, user_id, now) do
    case Map.fetch(state.members, user_id) do
      {:ok, entry} ->
        %{state | members: Map.put(state.members, user_id, %{entry | last_seen: now})}

      :error ->
        state
    end
  end

  defp evict_member(state, user_id) do
    new_state = %{
      state
      | members: Map.delete(state.members, user_id),
        typing: Map.delete(state.typing, user_id)
    }

    broadcast_room_update(new_state, :member_left, user_id)
    new_state
  end

  defp via_tuple(room_id) do
    {:via, Horde.Registry, {BeamChat.Registry, {:room, room_id}}}
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
