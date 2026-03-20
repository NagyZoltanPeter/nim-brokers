{.used.}

import testutils/unittests
import chronos
import std/[atomics, os]

import event_broker

## ---------------------------------------------------------------------------
## API-mode EventBroker tests
## ---------------------------------------------------------------------------
## These tests compile with -d:BrokerFfiApi --threads:on.
## They define API event brokers and test the generated C-callable
## registration functions directly from Nim.
## NOTE: We intentionally avoid `asyncTest` here. The event listener is
## registered from the main thread via an exported API function, and running the
## test body itself inside a pre-existing Chronos dispatcher is unstable under
## refc/debug. A plain `test` plus explicit `waitFor` keeps the main thread's
## event loop lifecycle aligned with the exported API runtime.

EventBroker(API):
  type ApiTestEvent = object
    message*: string
    code*: int32

# ── Global state for callback verification ──────────────────────────────
var gCallbackInvoked: Atomic[bool]
var gCallbackMessage: array[256, char]
var gCallbackCode: Atomic[int32]

proc testCallback(message: cstring, code: int32) {.cdecl.} =
  ## C-compatible callback that stores received values for verification.
  gCallbackCode.store(code)
  if not message.isNil():
    let msgLen = min(len($message), 255)
    for i in 0 ..< msgLen:
      gCallbackMessage[i] = ($message)[i]
    gCallbackMessage[msgLen] = '\0'
  gCallbackInvoked.store(true)

# ── Emitter thread ──────────────────────────────────────────────────────
var gEmitReady: Atomic[bool]

proc emitterThread(ctx: BrokerContext) {.thread.} =
  setThreadBrokerContext(ctx)
  gEmitReady.store(true)

  # Give listener time to register
  waitFor sleepAsync(chronos.milliseconds(200))

  # Emit an event
  waitFor ApiTestEvent.emit(ctx, ApiTestEvent(message: "hello from nim", code: 42))

  # Keep event loop alive for delivery
  waitFor sleepAsync(chronos.seconds(5))

suite "API EventBroker":
  test "register C callback and receive event":
    let ctx = NewBrokerContext()
    gCallbackInvoked.store(false)
    gCallbackCode.store(0)
    gEmitReady.store(false)

    # Start emitter thread
    var thread: Thread[BrokerContext]
    createThread(thread, emitterThread, ctx)

    while not gEmitReady.load():
      sleep(10)

    # Register C callback via generated exported function
    onApiTestEvent(uint32(ctx), testCallback)

    # Wait for the event to be delivered
    proc waitForCallback() {.async.} =
      var waited = 0
      while not gCallbackInvoked.load() and waited < 3000:
        await sleepAsync(chronos.milliseconds(50))
        waited += 50

    waitFor waitForCallback()

    check gCallbackInvoked.load() == true
    check gCallbackCode.load() == 42

    # Verify message
    var receivedMsg = ""
    var i = 0
    while gCallbackMessage[i] != '\0' and i < 256:
      receivedMsg.add(gCallbackMessage[i])
      inc i
    check receivedMsg == "hello from nim"

  test "deregister C callback":
    let ctx = NewBrokerContext()
    gCallbackInvoked.store(false)

    # Register and immediately deregister
    onApiTestEvent(uint32(ctx), testCallback)
    offApiTestEvent(uint32(ctx))

    # Emit — callback should NOT be invoked
    waitFor ApiTestEvent.emit(ctx, ApiTestEvent(message: "should not arrive", code: 99))
    waitFor sleepAsync(chronos.milliseconds(200))

    check gCallbackInvoked.load() == false
