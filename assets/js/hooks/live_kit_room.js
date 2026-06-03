// LiveKitRoom hook
// -----------------------------------------------------------------------------
// Bridges the LiveKit JS SDK with the `BeamChatWeb.VideoLive` LiveComponent.
// Listens for `livekit_connect` and `livekit_disconnect` push events from the
// server, manages a single `Room` instance, and emits state changes back as
// `video_connected`, `video_disconnected`, and `video_error` events.
//
// The hook never logs the JWT. It is held only in the closure used to call
// `Room.connect`.

import { Room, RoomEvent, ConnectionState } from "livekit-client"

const LiveKitRoom = {
  mounted() {
    this.room = null
    this.handleConnect = (payload) => this.connect(payload)
    this.handleDisconnect = () => this.disconnect()

    this.el.addEventListener("phx:livekit_connect", (e) => this.handleConnect(e.detail))
    this.el.addEventListener("phx:livekit_disconnect", () => this.handleDisconnect())
  },

  updated() {
    // No-op: state changes flow through push events. `updated` runs after the
    // server diff; we only need to react to explicit phx:* events.
  },

  destroyed() {
    this.disconnect()
  },

  async connect({ token, url }) {
    if (!token || !url) {
      this.pushError("Missing token or URL from server.")
      return
    }

    try {
      const room = new Room({
        adaptiveStream: true,
        dynacast: true,
        publishDefaults: { simulcast: true },
      })

      this.wireRoomEvents(room)

      await room.connect(url, token)
      this.room = room

      await this.publishDefaults(room)

      this.pushEvent("video_connected", { participants: room.numParticipants })
    } catch (err) {
      this.pushError(err && err.message ? err.message : "Failed to connect to video room.")
    }
  },

  wireRoomEvents(room) {
    room.on(RoomEvent.ParticipantConnected, () => {
      this.pushEvent("video_connected", { participants: room.numParticipants })
    })

    room.on(RoomEvent.ParticipantDisconnected, () => {
      this.pushEvent("video_connected", { participants: room.numParticipants })
    })

    room.on(RoomEvent.Disconnected, () => {
      this.pushEvent("video_disconnected", {})
    })

    room.on(RoomEvent.ConnectionStateChanged, (state) => {
      if (state === ConnectionState.Disconnected) {
        this.pushEvent("video_disconnected", {})
      }
    })
  },

  async publishDefaults(room) {
    try {
      await room.localParticipant.enableCameraAndMicrophone()
    } catch (err) {
      this.pushError(
        err && err.message
          ? "Camera/microphone unavailable: " + err.message
          : "Camera/microphone unavailable."
      )
    }
  },

  disconnect() {
    if (this.room) {
      try {
        this.room.disconnect()
      } catch (_e) {
        // Ignore — we are tearing down regardless.
      }
      this.room = null
      this.pushEvent("video_disconnected", {})
    }
  },

  pushError(message) {
    this.pushEvent("video_error", { message: message })
  },
}

export default LiveKitRoom
