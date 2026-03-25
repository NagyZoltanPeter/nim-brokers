{.used.}

import testutils/unittests
import chronos
import std/[atomics, os]

import event_broker

## ---------------------------------------------------------------------------
## API-mode EventBroker tests (delivery thread design)
## ---------------------------------------------------------------------------
## These tests compile with -d:BrokerFfiApi --threads:on.
## They define API event brokers and test the generated C-callable
## registration functions with the delivery-thread-based event system.
##
## Architecture:
## - Emitter thread: emits events (represents the processing thread)
## - Delivery thread: receives events cross-thread, calls C callbacks
##   (started manually here since we don't use registerBrokerLibrary)
## - Main thread: registers/deregisters C callbacks via on/off exports

EventBroker(API):
  type ApiTestEvent = object
    message*: string
    code*: int32

# ── Global state for callback verification ──────────────────────────────
var gCallbackInvoked: Atomic[bool]
var gCallbackMessage: array[256, char]
var gCallbackCode: Atomic[int32]
var gCallbackCount: Atomic[int32]
var gCallbackCtx: Atomic[uint32]
var gCallbackUserData: Atomic[int]
var gUserDataMarker = 0'i32

proc testCallback(
    ctx: uint32, userData: pointer, message: cstring, code: int32
) {.cdecl.} =
  ## C-compatible callback that stores received values for verification.
  gCallbackCtx.store(ctx)
  gCallbackUserData.store(cast[int](userData))
  gCallbackCode.store(code)
  if not message.isNil():
    let msgLen = min(len($message), 255)
    for i in 0 ..< msgLen:
      gCallbackMessage[i] = ($message)[i]
    gCallbackMessage[msgLen] = '\0'
  gCallbackInvoked.store(true)
  discard gCallbackCount.fetchAdd(1)

proc testCallback2(
    ctx: uint32, userData: pointer, message: cstring, code: int32
) {.cdecl.} =
  ## Second callback for multi-listener tests.
  discard ctx
  discard userData
  discard message
  discard code
  discard gCallbackCount.fetchAdd(1)

# ── Emitter thread ──────────────────────────────────────────────────────
proc emitterThread(ctx: BrokerContext) {.thread.} =
  setThreadBrokerContext(ctx)
  waitFor ApiTestEvent.emit(ctx, ApiTestEvent(message: "hello from nim", code: 42))

# ── Delivery thread ─────────────────────────────────────────────────────
# In production, registerBrokerLibrary creates this thread automatically.
# For unit tests, we create it manually with the event listener provider.

var gDelivReady: Atomic[bool]
var gStopDelivery: Atomic[bool]

proc deliveryThread(ctx: BrokerContext) {.thread.} =
  setThreadBrokerContext(ctx)

  # Install the provider for RegisterEventListenerResult
  # We build a simple provider that dispatches to the handler proc
  discard RegisterEventListenerResult.setProvider(
    ctx,
    proc(
        action: int32,
        eventTypeId: int32,
        callbackPtr: pointer,
        userData: pointer,
        listenerHandle: uint64,
    ): Future[Result[RegisterEventListenerResult, string]] {.closure, async.} =
      case eventTypeId
      of ApiTestEventApiTypeId:
        return await handleApiTestEventRegistration(
          ctx, action, callbackPtr, userData, listenerHandle
        )
      else:
        return err("Unknown event type: " & $eventTypeId),
  )

  gDelivReady.store(true)

  proc awaitUntilStopped() {.async: (raises: []).} =
    while not gStopDelivery.load():
      let catchRes = catch:
        await sleepAsync(chronos.milliseconds(1))
      if catchRes.isErr():
        break

    ApiTestEvent.dropAllListeners(ctx)
    RegisterEventListenerResult.clearProvider(ctx)

  waitFor awaitUntilStopped()

suite "API EventBroker (delivery thread)":
  test "register C callback and receive event":
    let ctx = NewBrokerContext()
    gCallbackInvoked.store(false)
    gCallbackCode.store(0)
    gCallbackCount.store(0)
    gDelivReady.store(false)
    gStopDelivery.store(false)

    # Start delivery thread first
    var delivThread: Thread[BrokerContext]
    createThread(delivThread, deliveryThread, ctx)
    defer:
      gStopDelivery.store(true)
      delivThread.joinThread()

    while not gDelivReady.load():
      sleep(10)

    # Register C callback via generated exported function
    # This uses waitFor internally to route request to delivery thread
    let expectedUserData = cast[pointer](addr gUserDataMarker)
    let handle = onApiTestEvent(uint32(ctx), testCallback, expectedUserData)
    check handle > 0'u64

    # Start emitter thread after listener registration completed
    var emitThread: Thread[BrokerContext]
    createThread(emitThread, emitterThread, ctx)
    defer:
      emitThread.joinThread()

    # Wait for the event to be delivered
    proc waitForCallback() {.async.} =
      var waited = 0
      while not gCallbackInvoked.load() and waited < 3000:
        await sleepAsync(chronos.milliseconds(50))
        waited += 50

    waitFor waitForCallback()

    check gCallbackInvoked.load() == true
    check gCallbackCtx.load() == uint32(ctx)
    check gCallbackUserData.load() == cast[int](expectedUserData)
    check gCallbackCode.load() == 42

    # Verify message
    var receivedMsg = ""
    var i = 0
    while gCallbackMessage[i] != '\0' and i < 256:
      receivedMsg.add(gCallbackMessage[i])
      inc i
    check receivedMsg == "hello from nim"

  test "onXxx returns handle, offXxx removes listener":
    let ctx = NewBrokerContext()
    gCallbackInvoked.store(false)
    gCallbackCount.store(0)
    gDelivReady.store(false)
    gStopDelivery.store(false)

    # Start delivery thread
    var delivThread: Thread[BrokerContext]
    createThread(delivThread, deliveryThread, ctx)
    defer:
      gStopDelivery.store(true)
      delivThread.joinThread()

    while not gDelivReady.load():
      sleep(10)

    # Register callback
    let handle =
      onApiTestEvent(uint32(ctx), testCallback, cast[pointer](addr gUserDataMarker))
    check handle > 0'u64

    # Deregister by handle
    offApiTestEvent(uint32(ctx), handle)

    # Emit — callback should NOT be invoked
    waitFor ApiTestEvent.emit(ctx, ApiTestEvent(message: "should not arrive", code: 99))
    waitFor sleepAsync(chronos.milliseconds(200))

    check gCallbackInvoked.load() == false

  test "offXxx with handle=0 removes all listeners":
    let ctx = NewBrokerContext()
    gCallbackCount.store(0)
    gDelivReady.store(false)
    gStopDelivery.store(false)

    # Start delivery thread
    var delivThread: Thread[BrokerContext]
    createThread(delivThread, deliveryThread, ctx)
    defer:
      gStopDelivery.store(true)
      delivThread.joinThread()

    while not gDelivReady.load():
      sleep(10)

    # Register two callbacks
    let h1 =
      onApiTestEvent(uint32(ctx), testCallback, cast[pointer](addr gUserDataMarker))
    let h2 = onApiTestEvent(uint32(ctx), testCallback2, nil)
    check h1 > 0'u64
    check h2 > 0'u64

    # Remove all with handle=0
    offApiTestEvent(uint32(ctx), 0'u64)

    # Emit — no callbacks should fire
    waitFor ApiTestEvent.emit(ctx, ApiTestEvent(message: "gone", code: 0))
    waitFor sleepAsync(chronos.milliseconds(200))

    check gCallbackCount.load() == 0
