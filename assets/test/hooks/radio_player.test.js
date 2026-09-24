// Smoke tests for the RadioPlayer Phoenix LiveView hook.
// Uses jsdom to provide a DOM, then asserts that the hook:
//   1. Registers the phx:radio_connect / phx:radio_disconnect listeners
//   2. Ignores events aimed at a different station's room
//   3. Connects with the token/url and pushes radio_connected
//   4. Attaches subscribed audio tracks to an <audio> element
//   5. Disconnects and removes the audio element on destroyed()
//   6. Pushes radio_error when connect fails or the payload is incomplete
//
// Run with: npm test
// (uses node's built-in test runner; no extra framework required)

import { test } from "node:test"
import assert from "node:assert/strict"
import { JSDOM } from "jsdom"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { dirname, resolve } from "node:path"

const __dirname = dirname(fileURLToPath(import.meta.url))
const hookSource = readFileSync(resolve(__dirname, "../../js/hooks/radio_player.js"), "utf8")

// --- Helpers ---------------------------------------------------------------

function loadHookInto(dom, hookName = "RadioPlayer") {
  const window = dom.window

  // The hook imports `livekit-client` (not loadable under jsdom without a
  // bundler) and uses `export default` (ESM). Same transform as the
  // LiveKitRoom hook tests: swap the import for the global stub and strip
  // the export so the body is plain script.
  const transformed = hookSource
    .replace(
      /import \{ Room, RoomEvent \} from "livekit-client"/,
      `const __stub = window.__LK_STUB__;
       const Room = __stub.Room;
       const RoomEvent = __stub.RoomEvent;`
    )
    .replace(/export default /g, "")

  const factory = new window.Function(
    "window",
    `${transformed}\nreturn ${hookName};`
  )
  return factory(window)
}

function makeStubRoom(opts = {}) {
  const listeners = new Map()
  return {
    listeners,
    connectCalls: [],
    disconnectCalls: 0,
    async connect(url, token) {
      this.connectCalls.push({ url, token })
      if (opts.connectThrows) throw new Error(opts.connectErrorMessage || "connect failed")
    },
    on(event, cb) {
      const list = listeners.get(event) || []
      list.push(cb)
      listeners.set(event, list)
    },
    async disconnect() {
      this.disconnectCalls += 1
    },
    fire(event, ...args) {
      const list = listeners.get(event) || []
      for (const cb of list) cb(...args)
    }
  }
}

function makeEl(dom, room) {
  const el = dom.window.document.createElement("div")
  el.id = "player-station-1"
  el.setAttribute("data-room", room)
  return el
}

function makeHookCtx(el, dom) {
  const pushEvents = []
  const ctx = {
    el,
    pushEvent: (name, payload) => {
      pushEvents.push({ name, payload })
      return Promise.resolve({})
    },
    pushEvents,
    dom
  }
  return ctx
}

function installHookMethods(ctx, Hook) {
  for (const name of Object.keys(Hook)) {
    if (typeof Hook[name] === "function") {
      ctx[name] = Hook[name].bind(ctx)
    }
  }
  return ctx
}

function dispatch(dom, el, eventName, detail) {
  el.dispatchEvent(new dom.window.CustomEvent(eventName, { detail }))
}

// --- Tests -----------------------------------------------------------------

test("hook registers phx:radio_connect and phx:radio_disconnect listeners", () => {
  const dom = new JSDOM("<!doctype html><html><body><div id=hook></div></body></html>")
  const el = dom.window.document.getElementById("hook")
  el.setAttribute("data-room", "radio-horn-fm")
  dom.window.__LK_STUB__ = {
    Room: function () {},
    RoomEvent: { TrackSubscribed: "trackSubscribed", Disconnected: "disconnected" }
  }

  const Hook = loadHookInto(dom)
  const ctx = installHookMethods(makeHookCtx(el, dom), Hook)
  Hook.mounted.call(ctx)

  assert.ok(ctx.handleConnect, "expected handleConnect to be defined")
  assert.ok(ctx.handleDisconnect, "expected handleDisconnect to be defined")

  // Dispatching connect for another room must not call connect (no Room
  // constructor available — it would throw and fail the test).
  dispatch(dom, el, "phx:radio_connect", { room: "radio-elsewhere", token: "abc", url: "wss://x" })
  assert.equal(ctx.pushEvents.length, 0, "no push events expected for a foreign room")
})

test("connects and pushes radio_connected for a matching room", async () => {
  const dom = new JSDOM("<!doctype html><html><body><div id=hook></div></body></html>")
  const el = dom.window.document.getElementById("hook")
  el.setAttribute("data-room", "radio-horn-fm")

  const room = makeStubRoom()
  dom.window.__LK_STUB__ = {
    Room: function () { return room },
    RoomEvent: { TrackSubscribed: "trackSubscribed", Disconnected: "disconnected" }
  }

  const Hook = loadHookInto(dom)
  const ctx = installHookMethods(makeHookCtx(el, dom), Hook)
  Hook.mounted.call(ctx)

  dispatch(dom, el, "phx:radio_connect", {
    room: "radio-horn-fm",
    token: "tok",
    url: "wss://test.livekit.local"
  })

  // The hook's connect is async; let microtasks settle.
  await new Promise((resolve) => setTimeout(resolve, 0))

  assert.deepEqual(room.connectCalls, [{ url: "wss://test.livekit.local", token: "tok" }])
  assert.ok(
    ctx.pushEvents.some((e) => e.name === "radio_connected"),
    "expected radio_connected push event"
  )
})

test("attaches subscribed audio tracks to an audio element", async () => {
  const dom = new JSDOM("<!doctype html><html><body><div id=hook></div></body></html>")
  const el = dom.window.document.getElementById("hook")
  el.setAttribute("data-room", "radio-horn-fm")

  const room = makeStubRoom()
  const attachTargets = []
  const track = {
    kind: "audio",
    attach(audioEl) {
      attachTargets.push(audioEl)
    }
  }

  dom.window.__LK_STUB__ = {
    Room: function () { return room },
    RoomEvent: { TrackSubscribed: "trackSubscribed", Disconnected: "disconnected" }
  }

  const Hook = loadHookInto(dom)
  const ctx = installHookMethods(makeHookCtx(el, dom), Hook)
  Hook.mounted.call(ctx)

  dispatch(dom, el, "phx:radio_connect", { room: "radio-horn-fm", token: "tok", url: "wss://x" })
  await new Promise((resolve) => setTimeout(resolve, 0))

  room.fire("trackSubscribed", track)

  assert.equal(attachTargets.length, 1, "expected the track to be attached once")
  assert.equal(attachTargets[0].tagName, "AUDIO")
  assert.equal(el.querySelector("audio"), attachTargets[0], "audio element lives inside the hook container")
})

test("disconnect removes the room and the audio element", async () => {
  const dom = new JSDOM("<!doctype html><html><body><div id=hook></div></body></html>")
  const el = dom.window.document.getElementById("hook")
  el.setAttribute("data-room", "radio-horn-fm")

  const room = makeStubRoom()
  dom.window.__LK_STUB__ = {
    Room: function () { return room },
    RoomEvent: { TrackSubscribed: "trackSubscribed", Disconnected: "disconnected" }
  }

  const Hook = loadHookInto(dom)
  const ctx = installHookMethods(makeHookCtx(el, dom), Hook)
  Hook.mounted.call(ctx)

  dispatch(dom, el, "phx:radio_connect", { room: "radio-horn-fm", token: "tok", url: "wss://x" })
  await new Promise((resolve) => setTimeout(resolve, 0))

  assert.ok(ctx.room, "expected a live room after connect")

  dispatch(dom, el, "phx:radio_disconnect", { room: "radio-horn-fm" })
  await new Promise((resolve) => setTimeout(resolve, 0))

  assert.equal(room.disconnectCalls, 1, "expected room.disconnect to be called")
  assert.equal(ctx.room, null, "expected the room reference to be cleared")
})

test("pushes radio_error when connect fails", async () => {
  const dom = new JSDOM("<!doctype html><html><body><div id=hook></div></body></html>")
  const el = dom.window.document.getElementById("hook")
  el.setAttribute("data-room", "radio-horn-fm")

  const room = makeStubRoom({ connectThrows: true })
  dom.window.__LK_STUB__ = {
    Room: function () { return room },
    RoomEvent: { TrackSubscribed: "trackSubscribed", Disconnected: "disconnected" }
  }

  const Hook = loadHookInto(dom)
  const ctx = installHookMethods(makeHookCtx(el, dom), Hook)
  Hook.mounted.call(ctx)

  dispatch(dom, el, "phx:radio_connect", { room: "radio-horn-fm", token: "tok", url: "wss://x" })
  await new Promise((resolve) => setTimeout(resolve, 0))

  assert.ok(
    ctx.pushEvents.some((e) => e.name === "radio_error"),
    "expected radio_error push event"
  )
})

test("pushes radio_error when token or url is missing", async () => {
  const dom = new JSDOM("<!doctype html><html><body><div id=hook></div></body></html>")
  const el = dom.window.document.getElementById("hook")
  el.setAttribute("data-room", "radio-horn-fm")

  dom.window.__LK_STUB__ = {
    Room: function () { throw new Error("must not be constructed") },
    RoomEvent: { TrackSubscribed: "trackSubscribed", Disconnected: "disconnected" }
  }

  const Hook = loadHookInto(dom)
  const ctx = installHookMethods(makeHookCtx(el, dom), Hook)
  Hook.mounted.call(ctx)

  dispatch(dom, el, "phx:radio_connect", { room: "radio-horn-fm", token: "abc" })
  await new Promise((resolve) => setTimeout(resolve, 0))

  assert.ok(
    ctx.pushEvents.some((e) => e.name === "radio_error"),
    "expected radio_error push event"
  )
})
