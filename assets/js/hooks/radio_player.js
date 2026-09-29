// RadioPlayer hook
// -----------------------------------------------------------------------------
// Subscribe-only LiveKit audio player for radio stations. One hook instance
// lives on each station's player container (carrying data-room). The server
// broadcasts `radio_connect` / `radio_disconnect` push events to the whole
// view; each hook reacts only when the event's `room` matches its own
// station, so multiple stations can coexist on the page.
//
// Server push events are consumed via `this.handleEvent` — the sanctioned
// hook API. LiveView dispatches `phx:<event>` CustomEvents on `window`, so
// element-scoped addEventListener would never fire.
//
// The hook attaches the incoming audio track to an <audio> element it
// creates inside its container and never publishes anything back to the
// room (listener tokens are subscribe-only by construction).
//
// The hook never logs the JWT. It is held only in the closure used to call
// `Room.connect`.

import { Room, RoomEvent } from "livekit-client"

const RadioPlayer = {
  mounted() {
    this.room = null
    this.audioEl = null

    this.handleEvent("radio_connect", (payload) => {
      if (payload && payload.room === this.el.dataset.room) {
        this.connect(payload)
      }
    })

    this.handleEvent("radio_disconnect", (payload) => {
      // A disconnect without a room matches everyone (view-level teardown);
      // a room-scoped disconnect only matches this station.
      if (!payload || payload.room === this.el.dataset.room) {
        this.disconnect(true)
      }
    })
  },

  destroyed() {
    this.disconnect(true)
  },

  async connect({ token, url }) {
    if (!token || !url) {
      this.pushError("Missing token or URL from server.")
      return
    }

    // A previous connection on this hook (e.g. re-connecting the same
    // station) is torn down first.
    this.disconnect(true)

    try {
      const room = new Room({ autoSubscribe: true })

      room.on(RoomEvent.TrackSubscribed, (track) => {
        if (track.kind === "audio") {
          this.attachAudio(track)
        }
      })

      room.on(RoomEvent.Disconnected, () => {
        this.pushEvent("radio_disconnected", {})
      })

      await room.connect(url, token)
      this.room = room

      this.pushEvent("radio_connected", {})
    } catch (err) {
      this.pushError(err && err.message ? err.message : "Failed to connect to the station.")
    }
  },

  attachAudio(track) {
    if (this.audioEl) {
      this.audioEl.remove()
    }

    this.audioEl = this.el.ownerDocument.createElement("audio")
    this.audioEl.controls = false
    this.audioEl.autoplay = true
    this.audioEl.style.display = "none"
    this.el.appendChild(this.audioEl)

    track.attach(this.audioEl)
  },

  disconnect(silent) {
    if (this.room) {
      try {
        this.room.disconnect()
      } catch (_e) {
        // Ignore — we are tearing down regardless.
      }
      this.room = null
    }

    if (this.audioEl) {
      this.audioEl.remove()
      this.audioEl = null
    }

    if (!silent) {
      this.pushEvent("radio_disconnected", {})
    }
  },

  pushError(message) {
    this.pushEvent("radio_error", { message: message })
  },
}

export default RadioPlayer
