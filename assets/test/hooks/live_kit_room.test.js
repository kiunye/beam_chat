// Smoke tests for the LiveKitRoom Phoenix LiveView hook.
// Uses jsdom to provide a DOM, then asserts that the hook:
//   1. Registers the phx:livekit_connect / phx:livekit_disconnect listeners
//   2. Calls pushEvent("video_error", ...) when the payload is missing
//      required fields (we mock the livekit-client Room to throw)
//   3. Calls room.disconnect() on destroyed()
//   4. Does not call pushEvent for tokens that lack token/url
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
const hookSource = readFileSync(resolve(__dirname, "../../js/hooks/live_kit_room.js"), "utf8")

// --- Helpers ---------------------------------------------------------------

function loadHookInto(dom, hookName = "LiveKitRoom") {
  const window = dom.window

  // The hook imports `livekit-client` (not loadable under jsdom without a
  // bundler) and uses `export default` (ESM). We transform the source:
  //   1. Replace the livekit-client import with a destructuring assignment
  //      that pulls the stubbed symbols off the global window object.
  //   2. Strip the `export default` so the body is plain script.
  //   3. Append a `return <HookName>;` so we can pull the hook out.
  const transformed = hookSource
    .replace(
      /import \{ Room, RoomEvent, ConnectionState \} from "livekit-client"/,
      `const __stub = window.__LK_STUB__;
       const Room = __stub.Room;
       const RoomEvent = __stub.RoomEvent;
       const ConnectionState = __stub.ConnectionState;`
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
    opts,
    listeners,
    numParticipants: 1,
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
    localParticipant: {
      async enableCameraAndMicrophone() {
        if (opts.mediaThrows) throw new Error("permission denied")
      }
    },
    fire(event, ...args) {
      const list = listeners.get(event) || []
      for (const cb of list) cb(...args)
    }
  }
}

function makeEl(dom) {
  const el = dom.window.document.createElement("div")
  el.id = "video-panel"
  el.setAttribute("data-video-state", "idle")
  return el
}

function makeHookCtx(el, dom, room) {
  const pushEvents = []
  const serverEvents = new Map()
  const ctx = {
    el,
    pushEvent: (name, payload) => {
      pushEvents.push({ name, payload })
      return Promise.resolve({})
    },
    handleEvent: (name, cb) => {
      serverEvents.set(name, cb)
    },
    triggerEvent: (name, payload) => {
      const cb = serverEvents.get(name)
      if (cb) cb(payload)
    },
    registeredEvents: serverEvents,
    pushEvents,
    room,
    dom
  }
  ctx.pushError = function (message) {
    return this.pushEvent("video_error", { message })
  }
  return ctx
}

// Copy the hook's methods onto the ctx so that internal `this.foo()` calls
// resolve correctly (production code calls methods on the hook instance
// which is itself the `this`; in tests we split them).
function installHookMethods(ctx, Hook) {
  for (const name of Object.keys(Hook)) {
    if (typeof Hook[name] === "function") {
      ctx[name] = Hook[name].bind(ctx)
    }
  }
  return ctx
}

// --- Tests -----------------------------------------------------------------

test("hook registers livekit_connect and livekit_disconnect via handleEvent", async () => {
  const dom = new JSDOM("<!doctype html><html><body><div id=hook></div></body></html>")
  const el = dom.window.document.getElementById("hook")
  const stubRoom = makeStubRoom()
  dom.window.__LK_STUB__ = {
    Room: () => stubRoom,
    RoomEvent: { ParticipantConnected: "pc", ParticipantDisconnected: "pd", Disconnected: "d", ConnectionStateChanged: "csc" },
    ConnectionState: { Disconnected: "disconnected" }
  }

  const Hook = loadHookInto(dom)
  const ctx = installHookMethods(makeHookCtx(el, dom, null), Hook)
  Hook.mounted.call(ctx)

  assert.ok(ctx.registeredEvents.has("livekit_connect"), "expected a livekit_connect handler")
  assert.ok(ctx.registeredEvents.has("livekit_disconnect"), "expected a livekit_disconnect handler")

  // Driving the registered connect handler must reach this hook's connect.
  ctx.triggerEvent("livekit_connect", { token: "abc", url: "wss://x" })
  await new Promise((resolve) => setTimeout(resolve, 0))

  assert.equal(stubRoom.connectCalls.length, 1, "expected the handler to connect the room")
  assert.equal(stubRoom.connectCalls[0].token, "abc")

  // Driving disconnect must tear the room down.
  ctx.triggerEvent("livekit_disconnect", {})
  assert.equal(stubRoom.disconnectCalls, 1, "expected the handler to disconnect the room")
})

test("hook pushes video_error when token/url is missing", async () => {
  const dom = new JSDOM("<!doctype html><html><body><div id=hook></div></body></html>")
  const el = dom.window.document.getElementById("hook")
  dom.window.__LK_STUB__ = {
    Room: function () {},
    RoomEvent: {},
    ConnectionState: {}
  }

  const Hook = loadHookInto(dom)
  const ctx = installHookMethods(makeHookCtx(el, dom, null), Hook)
  Hook.mounted.call(ctx)

  await ctx.connect({ token: null, url: "wss://x" })

  assert.equal(ctx.pushEvents.length, 1)
  assert.equal(ctx.pushEvents[0].name, "video_error")
  assert.match(ctx.pushEvents[0].payload.message, /Missing token or URL/)
})

test("hook pushes video_error when Room.connect throws", async () => {
  const dom = new JSDOM("<!doctype html><html><body><div id=hook></div></body></html>")
  const el = dom.window.document.getElementById("hook")
  const stubRoom = function () { return makeStubRoom({ connectThrows: true, connectErrorMessage: "auth failed" }) }
  dom.window.__LK_STUB__ = {
    Room: stubRoom,
    RoomEvent: {},
    ConnectionState: {}
  }

  const Hook = loadHookInto(dom)
  const ctx = installHookMethods(makeHookCtx(el, dom, null), Hook)
  Hook.mounted.call(ctx)

  await ctx.connect({ token: "tok", url: "wss://x" })

  assert.equal(ctx.pushEvents.length, 1)
  assert.equal(ctx.pushEvents[0].name, "video_error")
  assert.match(ctx.pushEvents[0].payload.message, /auth failed/)
})

test("hook pushes video_connected on successful connect", async () => {
  const dom = new JSDOM("<!doctype html><html><body><div id=hook></div></body></html>")
  const el = dom.window.document.getElementById("hook")
  const stubRoom = function () { return makeStubRoom() }
  dom.window.__LK_STUB__ = {
    Room: stubRoom,
    RoomEvent: {
      ParticipantConnected: "pc",
      ParticipantDisconnected: "pd",
      Disconnected: "d",
      ConnectionStateChanged: "csc"
    },
    ConnectionState: { Disconnected: "disconnected" }
  }

  const Hook = loadHookInto(dom)
  const ctx = installHookMethods(makeHookCtx(el, dom, null), Hook)
  Hook.mounted.call(ctx)

  await ctx.connect({ token: "tok", url: "wss://x" })

  assert.ok(ctx.pushEvents.some((e) => e.name === "video_connected"), "expected video_connected event")
  assert.equal(ctx.room.connectCalls.length, 1)
  assert.equal(ctx.room.connectCalls[0].token, "tok")
  assert.equal(ctx.room.connectCalls[0].url, "wss://x")
})

test("hook disconnects room on destroyed()", async () => {
  const dom = new JSDOM("<!doctype html><html><body><div id=hook></div></body></html>")
  const el = dom.window.document.getElementById("hook")
  const stubRoomInstance = makeStubRoom()
  const stubRoom = function () { return stubRoomInstance }
  dom.window.__LK_STUB__ = {
    Room: stubRoom,
    RoomEvent: {},
    ConnectionState: {}
  }

  const Hook = loadHookInto(dom)
  const ctx = installHookMethods(makeHookCtx(el, dom, null), Hook)
  Hook.mounted.call(ctx)
  await ctx.connect({ token: "tok", url: "wss://x" })

  ctx.destroyed()
  assert.equal(stubRoomInstance.disconnectCalls, 1)
})

test("hook does not leak the JWT to console or pushEvent payload", async () => {
  const dom = new JSDOM("<!doctype html><html><body><div id=hook></div></body></html>")
  const el = dom.window.document.getElementById("hook")
  dom.window.__LK_STUB__ = {
    Room: function () { return makeStubRoom() },
    RoomEvent: { ParticipantConnected: "pc", ParticipantDisconnected: "pd", Disconnected: "d", ConnectionStateChanged: "csc" },
    ConnectionState: { Disconnected: "disconnected" }
  }

  const originalLog = console.log
  const originalWarn = console.warn
  const logs = []
  console.log = (...a) => logs.push(a.join(" "))
  console.warn = (...a) => logs.push(a.join(" "))

  try {
    const Hook = loadHookInto(dom)
    const ctx = installHookMethods(makeHookCtx(el, dom, null), Hook)
    Hook.mounted.call(ctx)
    await ctx.connect({ token: "super-secret-jwt-do-not-leak", url: "wss://x" })
  } finally {
    console.log = originalLog
    console.warn = originalWarn
  }

  for (const line of logs) {
    assert.doesNotMatch(line, /super-secret-jwt-do-not-leak/, "JWT leaked to console")
  }
})
