{.used.}

import testutils/unittests
import chronos
import std/[atomics, os]

import brokers/request_broker

## ---------------------------------------------------------------------------
## MT RequestBroker — `setRequestTimeout(InfiniteDuration)` on the blocking path
##
## The blocking wait computed `Moment.now() + timeout`, which overflows int64
## for `InfiniteDuration`: `OverflowDefect` with overflow checks on, a negative
## (already expired) deadline without. The async path goes through chronos
## `withTimeout`, which handles infinity itself.
## ---------------------------------------------------------------------------

RequestBroker(mt):
  type InfReq = object
    echoed*: string

  proc signature*(input: string): Future[Result[InfReq, string]] {.async.}

const ReplyDelayMs = 100
  ## Long enough that the blocking wait loops a while before the reply lands.

var gProviderReady: Atomic[bool]
var gStopProvider: Atomic[bool]
var gBlockingOk: Atomic[bool]
var gCancellableOk: Atomic[bool]
var gCancelId: InfReqRequestId

proc infProvider(input: string): Future[Result[InfReq, string]] {.async.} =
  await sleepAsync(chronos.milliseconds(ReplyDelayMs))
  ok(InfReq(echoed: input))

proc providerThreadProc() {.thread.} =
  doAssert InfReq.setProvider(infProvider).isOk()
  gProviderReady.store(true)
  while not gStopProvider.load():
    waitFor sleepAsync(chronos.milliseconds(10))
  InfReq.clearProvider()
  waitFor sleepAsync(chronos.milliseconds(50))

proc requesterThreadProc() {.thread.} =
  # Plain thread: no event loop, so this is the polled blocking wait.
  let r1 = InfReq.blockingRequest("plain")
  gBlockingOk.store(r1.isOk() and r1.value.echoed == "plain")
  let r2 = InfReq.blockingRequestCancellable("cancellable", addr gCancelId)
  gCancellableOk.store(r2.isOk() and r2.value.echoed == "cancellable")

suite "MT RequestBroker — infinite request timeout":
  test "blocking requests wait for the reply under InfiniteDuration":
    InfReq.setRequestTimeout(InfiniteDuration)
    gProviderReady.store(false)
    gStopProvider.store(false)

    var provThread: Thread[void]
    provThread.createThread(providerThreadProc)
    while not gProviderReady.load():
      sleep(5)

    var reqThread: Thread[void]
    reqThread.createThread(requesterThreadProc)
    reqThread.joinThread()

    gStopProvider.store(true)
    provThread.joinThread()

    check gBlockingOk.load()
    check gCancellableOk.load()

    InfReq.setRequestTimeout(chronos.seconds(20))
