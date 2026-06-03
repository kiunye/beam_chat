defmodule BeamChatWeb.VideoLive do
  @moduledoc """
  LiveComponent that handles joining and leaving the LiveKit audio/video
  room for a chat room. Renders an idle "Join video" button; on click asks
  `BeamChat.Video.TokenService` for a short-lived JWT and pushes a
  `livekit_connect` event to the client-side `LiveKitRoom` hook.

  State is local to the component; the parent `RoomLive.Show` does not need
  to know whether the user has the camera on. When the user leaves, we push
  `livekit_disconnect` to the hook and the panel returns to its idle state.
  """

  use BeamChatWeb, :live_component

  alias BeamChat.Rooms.AccessPolicy
  alias BeamChat.Video.TokenService

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:video_state, :idle)
     |> assign(:video_error, nil)}
  end

  @impl true
  def update(assigns, socket) do
    # `update/2` is called both for initial parent-driven updates and for
    # `send_update/3` calls from `RoomLive.Show` (which only pass a subset of
    # assigns). Only merge keys that the parent actually sent.
    socket =
      Enum.reduce(assigns, socket, fn {key, value}, acc ->
        case key do
          :video_state -> assign(acc, :video_state, value)
          :video_error -> assign(acc, :video_error, value)
          :participant_count -> assign(acc, :participant_count, value)
          _ -> assign(acc, key, value)
        end
      end)

    {:ok, socket}
  end

  @impl true
  def handle_event("join_video", _params, socket) do
    room = socket.assigns.room
    user = socket.assigns.current_user

    if AccessPolicy.can_video?(room, user) do
      case TokenService.generate_token(user, room.id) do
        {:ok, payload} ->
          {:noreply,
           socket
           |> assign(:video_state, :joining)
           |> assign(:video_error, nil)
           |> push_event("livekit_connect", payload)}

        {:error, :not_configured} ->
          {:noreply,
           socket
           |> assign(:video_state, :idle)
           |> put_flash(:error, "Video is not configured. Contact an administrator.")
           |> assign(:video_error, "LiveKit is not configured on this server.")}
      end
    else
      {:noreply,
       socket
       |> assign(:video_state, :idle)
       |> put_flash(:error, "You do not have permission to join the video room.")}
    end
  end

  def handle_event("leave_video", _params, socket) do
    {:noreply,
     socket
     |> assign(:video_state, :idle)
     |> assign(:video_error, nil)
     |> push_event("livekit_disconnect", %{})}
  end

  def handle_event("video_connected", %{"participants" => count}, socket)
      when is_integer(count) do
    {:noreply,
     socket
     |> assign(:video_state, :connected)
     |> assign(:participant_count, count)}
  end

  def handle_event("video_disconnected", _params, socket) do
    {:noreply,
     socket
     |> assign(:video_state, :idle)
     |> assign(:video_error, nil)}
  end

  def handle_event("video_error", %{"message" => message}, socket) when is_binary(message) do
    {:noreply,
     socket
     |> assign(:video_state, :error)
     |> assign(:video_error, message)}
  end

  attr :id, :string, default: "video-panel"
  attr :room, :map, required: true
  attr :current_user, :any, required: true
  attr :can_video, :boolean, default: false

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      data-video-state={@video_state}
      phx-hook={@can_video && "LiveKitRoom"}
      phx-update="ignore"
      class="rounded-box border border-base-300 bg-base-200/40 p-3 space-y-2"
    >
      <div class="flex items-center justify-between">
        <h3 class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Video room</h3>

        <span
          :if={@video_state == :connected}
          class="badge badge-success badge-sm"
          id="video-participant-count"
        >
          {@participant_count || 1} live
        </span>
      </div>

      <p :if={!@can_video} class="text-xs text-base-content/60">
        Video is not available for this room.
      </p>

      <p
        :if={@can_video && @video_state == :error && @video_error}
        class="text-xs text-error"
        id="video-error-message"
      >
        {@video_error}
      </p>

      <div :if={@can_video} class="flex flex-wrap gap-2">
        <button
          :if={@video_state in [:idle, :error]}
          type="button"
          phx-click="join_video"
          phx-target={@myself}
          class="btn btn-primary btn-sm"
          id="video-join-button"
        >
          Join video
        </button>
        <button
          :if={@video_state in [:joining, :connected]}
          type="button"
          phx-click="leave_video"
          phx-target={@myself}
          class="btn btn-outline btn-sm"
          id="video-leave-button"
        >
          Leave video
        </button>
        <span
          :if={@video_state == :joining}
          class="text-xs text-base-content/60 self-center"
          id="video-status"
        >
          Connecting…
        </span>
      </div>
    </div>
    """
  end
end
