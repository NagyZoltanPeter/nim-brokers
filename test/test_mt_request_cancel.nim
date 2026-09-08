{.used.}

import testutils/unittests
import chronos
import std/[atomics, os, strutils]

import brokers/request_broker

## ---------------------------------------------------------------------------
## MT RequestBroker — explicit cancellation
##
## `requestCancellable` hands back an opaque request id together with the
## response future; any thread may pass that id to `cancel`. Two effects:
##
##   * a request that has not been dispatched yet is dropped at the consumer
##     (the provider is never invoked), and
##   * a request already running has its provider future cancelled.
##
## Either way the requester resolves with an err, and the response slot goes
## back to the pool exactly once. A stale id (request already finished, slot
## recycled) fails the generation check and is a no-op.
## ---------------------------------------------------------------------------

RequestBroker(mt, queueDepth = 16, slabCapacity = 8, responseSlots = 4):
  type CancelReq = object
    echoed*: string

  proc signature*(input: string): Future[Result[CancelReq, string]] {.async.}

var gInvocations: Atomic[int]
var gSecondInvoked: Atomic[bool]
var gCancelledInFlight: Atomic[bool]
var gPublishedId: Atomic[uint64]
var gDone: Atomic[bool]
var gOutcomeOk: Atomic[bool]
var gElapsedMs: Atomic[int]

proc cancelProvider(input: string): Future[Result[CancelReq, string]] {.async.} =
  discard gInvocations.fetchAdd(1)
  if input == "second":
    gSecondInvoked.store(true)
  if input.startsWith("slow:"):
    try:
      await sleepAsync(chronos.seconds(30))
    except CancelledError as exc:
      gCancelledInFlight.store(true)
      raise exc
  elif input == "block":
    # Deliberately blocks this thread's event loop, so anything enqueued
    # during the window stays in the ring instead of being dispatched.
    sleep(400)
  ok(CancelReq(echoed: input))

# ── in-flight cancellation ───────────────────────────────────────────────

proc requesterInFlight() {.thread.} =
  let (id, fut) = CancelReq.requestCancellable("slow:one")
  doAssert uint64(id) != 0'u64, "expected a cancellable id"
  gPublishedId.store(uint64(id))
  let started = Moment.now()
  let res = waitFor fut
  let elapsed = int((Moment.now() - started).milliseconds)
  gElapsedMs.store(elapsed)
  gOutcomeOk.store(res.isErr() and "cancelled" in res.error)
  gDone.store(true)

# ── cancellation of a request still sitting in the queue ─────────────────

proc requesterQueued() {.thread.} =
  # First request blocks the provider thread's loop; the second lands in the
  # ring behind it and is cancelled before the provider can dequeue it.
  let firstFut = CancelReq.request("block")
  sleep(50) # let "block" reach the provider and start blocking
  let (id, secondFut) = CancelReq.requestCancellable("second")
  doAssert uint64(id) != 0'u64
  discard CancelReq.cancel(id)
  let second = waitFor secondFut
  let first = waitFor firstFut
  gOutcomeOk.store(
    second.isErr() and "cancelled" in second.error and first.isOk() and
      first.value.echoed == "block"
  )
  gDone.store(true)

# ── stale id: cancelling a finished request must not disturb the pool ────

proc requesterStaleId() {.thread.} =
  let (id, fut) = CancelReq.requestCancellable("first")
  let first = waitFor fut
  doAssert first.isOk() and first.value.echoed == "first", "first request failed"
  # The slot is back in the pool and its generation has moved on: cancelling
  # the finished request must report "nothing to cancel" and must not touch
  # whatever claims that slot next.
  let cancelledLate = CancelReq.cancel(id)
  var laterOk = true
  for i in 0 ..< 6:
    let want = "later-" & $i
    let r = waitFor CancelReq.request(want)
    if r.isErr() or r.value.echoed != want:
      laterOk = false
  gOutcomeOk.store((not cancelledLate) and laterOk)
  gDone.store(true)

# ── blocking caller cancelled by a third thread ──────────────────────────

## The blocking caller cannot hand its id out after the fact — it is stuck in
## the call — so the prologue writes it straight into shared storage the
## canceller can read.
var gBlockingId: CancelReqRequestId

proc requesterBlockingCancellable() {.thread.} =
  let res = CancelReq.blockingRequestCancellable("slow:blocking", addr gBlockingId)
  gOutcomeOk.store(res.isErr() and "cancelled" in res.error)
  gDone.store(true)

# ── cancelling through the future itself ─────────────────────────────────

proc cancelViaFuture(): Future[bool] {.async: (raises: []).} =
  ## The returned future owns its cancel schedule, so cancelling it is routed
  ## into the broker's cancel path instead of raising `CancelledError` inside a
  ## `raises: []` waiter that could not handle it.
  let (id, fut) = CancelReq.requestCancellable("slow:via-future")
  if uint64(id) == 0'u64:
    return false
  fut.cancelSoon()
  let res = await fut
  res.isErr() and "cancelled" in res.error

proc cancelViaWithTimeout(): Future[bool] {.async: (raises: [CatchableError]).} =
  ## `withTimeout` cancels the future it wraps when the deadline passes — the
  ## combinator case that used to drive an unhandled `CancelledError`.
  let (id, fut) = CancelReq.requestCancellable("slow:with-timeout")
  if uint64(id) == 0'u64:
    return false
  # The return value is deliberately not asserted: because the cancellation is
  # routed into the broker and resolves the future, `withTimeout` observes it
  # as finished and reports `true`. What matters is that the request is
  # cancelled and the future carries a normal err instead of an unhandled
  # `CancelledError`.
  discard await withTimeout(fut, chronos.milliseconds(100))
  let res = await fut
  res.isErr() and "cancelled" in res.error

proc requesterFutureCancel() {.thread.} =
  let viaFuture = waitFor cancelViaFuture()
  var viaTimeout = false
  try:
    viaTimeout = waitFor cancelViaWithTimeout()
  except CatchableError:
    viaTimeout = false
  gOutcomeOk.store(viaFuture and viaTimeout)
  gDone.store(true)

suite "MT RequestBroker — explicit cancellation":
  asyncTest "cancel unblocks an in-flight request and cancels the provider":
    check CancelReq.setProvider(cancelProvider).isOk()
    gDone.store(false)
    gOutcomeOk.store(false)
    gPublishedId.store(0'u64)
    gCancelledInFlight.store(false)

    var th: Thread[void]
    th.createThread(requesterInFlight)
    while gPublishedId.load() == 0'u64:
      await sleepAsync(chronos.milliseconds(5))
    # Give the provider a moment to actually start running the request.
    await sleepAsync(chronos.milliseconds(100))
    check CancelReq.cancel(CancelReqRequestId(gPublishedId.load()))

    while not gDone.load():
      await sleepAsync(chronos.milliseconds(5))
    th.joinThread()

    check gOutcomeOk.load()
    # Resolved by the cancel, not by the 20 s default request timeout.
    check gElapsedMs.load() < 2000
    check gCancelledInFlight.load()

    CancelReq.clearProvider()

  asyncTest "cancelling a queued request never invokes the provider":
    check CancelReq.setProvider(cancelProvider).isOk()
    gDone.store(false)
    gOutcomeOk.store(false)
    gSecondInvoked.store(false)

    var th: Thread[void]
    th.createThread(requesterQueued)
    while not gDone.load():
      await sleepAsync(chronos.milliseconds(5))
    th.joinThread()

    check gOutcomeOk.load()
    check not gSecondInvoked.load()

    CancelReq.clearProvider()

  asyncTest "a blocking request can be cancelled from another thread":
    check CancelReq.setProvider(cancelProvider).isOk()
    gDone.store(false)
    gOutcomeOk.store(false)
    gBlockingId = CancelReqRequestId(0)

    var th: Thread[void]
    th.createThread(requesterBlockingCancellable)
    while uint64(gBlockingId) == 0'u64:
      await sleepAsync(chronos.milliseconds(5))
    await sleepAsync(chronos.milliseconds(50))
    check CancelReq.cancel(gBlockingId)

    while not gDone.load():
      await sleepAsync(chronos.milliseconds(5))
    th.joinThread()

    check gOutcomeOk.load()

    CancelReq.clearProvider()

  asyncTest "cancelling the response future routes into the cancel path":
    check CancelReq.setProvider(cancelProvider).isOk()
    gDone.store(false)
    gOutcomeOk.store(false)
    gCancelledInFlight.store(false)

    var th: Thread[void]
    th.createThread(requesterFutureCancel)
    while not gDone.load():
      await sleepAsync(chronos.milliseconds(5))
    th.joinThread()

    check gOutcomeOk.load()

    CancelReq.clearProvider()

  asyncTest "cancelling a completed request is a no-op":
    check CancelReq.setProvider(cancelProvider).isOk()
    gDone.store(false)
    gOutcomeOk.store(false)

    var th: Thread[void]
    th.createThread(requesterStaleId)
    while not gDone.load():
      await sleepAsync(chronos.milliseconds(5))
    th.joinThread()

    check gOutcomeOk.load()

    CancelReq.clearProvider()
