{.used.}

import testutils/unittests
import chronos
import std/[atomics, os]

import event_broker

EventBroker(API):
  type ApiTestEvent = object
    message*: string
    code*: int32

var gEmitReady: Atomic[bool]
var gCallbackInvoked: Atomic[bool]

proc testCallback(message: cstring, code: int32) {.cdecl.} =
  echo "callback: code=", code
  gCallbackInvoked.store(true)

proc emitterThread(ctx: BrokerContext) {.thread.} =
  echo "emitter: starting"
  setThreadBrokerContext(ctx)
  gEmitReady.store(true)

  proc run() {.async.} =
    await sleepAsync(chronos.milliseconds(200))
    echo "emitter: about to emit"
    await ApiTestEvent.emit(ctx, ApiTestEvent(message: "hello", code: 42))
    echo "emitter: emitted"
    await sleepAsync(chronos.seconds(2))

  waitFor run()

suite "API EventBroker":
  test "register then emit cross-thread (no asyncTest)":
    let ctx = NewBrokerContext()
    gCallbackInvoked.store(false)
    gEmitReady.store(false)

    # Register callback on main thread (creates chronos dispatcher)
    onApiTestEvent(uint32(ctx), testCallback)
    echo "test: callback registered"

    echo "test: spawning emitter"
    var thread: Thread[BrokerContext]
    createThread(thread, emitterThread, ctx)

    # Busy-wait for emitter
    while not gEmitReady.load():
      sleep(10)
    echo "test: emitter ready"

    # We need to run chronos on main thread to process events
    # (processLoop runs on the listener thread which is main thread)
    proc waitForCallback() {.async.} =
      var waited = 0
      while not gCallbackInvoked.load() and waited < 3000:
        await sleepAsync(chronos.milliseconds(50))
        waited += 50

    waitFor waitForCallback()
    echo "test: done, invoked=", gCallbackInvoked.load()
    check gCallbackInvoked.load() == true
