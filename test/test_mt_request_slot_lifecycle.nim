{.used.}

import testutils/unittests
import chronos
import std/[atomics, os, strutils]

import brokers/request_broker
import brokers/internal/mt_broker_common

## ---------------------------------------------------------------------------
## MT RequestBroker — response-slot lifecycle regression gates
##
## These cover the give-up (timeout) paths of the cross-thread request lane,
## where the requester stops waiting before the provider replies:
##
##   A-1  a timed-out request must not leave a stale response poller behind
##        that later steals / double-releases a reused slot,
##   A-3  a late reply (provider already mid-write when the deadline fired)
##        must still return its slot to the pool — on the async *and* the
##        blocking path,
##   A-2  no poller may outlive the pool it points at (visible under ASAN /
##        refc once the provider thread tears down its bucket).
##
## The broker below is deliberately configured with a 2-slot response pool and
## a single free-list shard, so slot indices are recycled immediately and any
## bookkeeping error shows up within a handful of requests instead of needing
## the 256-slot default to churn.
## ---------------------------------------------------------------------------

RequestBroker(
  mt,
  queueDepth = 16,
  slabCapacity = 8,
  maxPayloadBytes = 256,
  responseSlots = 2,
  maxResponseBytes = 512,
  freeListShards = 1,
):
  type SlotReq = object
    echoed*: string

  proc signature*(input: string): Future[Result[SlotReq, string]] {.async.}

const
  SlowDelay = 800
  EdgeDelay = 3
    ## Deliberately close to the blocking path's 1 ms poll granularity: with a
    ## coarse delay the give-up almost always finds an untouched slot, and the
    ## "provider already published / already writing" branches — the ones that
    ## decide who owes the release — never get exercised.
  BlockDelay = 500

var gQueuedInvoked: Atomic[bool]

proc slotProvider(input: string): Future[Result[SlotReq, string]] {.async.} =
  ## `slow:` sleeps well past the requester's deadline (forces the
  ## "requester abandoned first" branch); `edge:` sleeps exactly the
  ## deadline (races the abandon CAS, exercising the "provider already
  ## mid-write" branch); `block` stalls this thread's event loop so a
  ## following request stays in the ring; anything else replies immediately.
  if input.startsWith("queued:"):
    gQueuedInvoked.store(true)
  if input.startsWith("slow:"):
    await sleepAsync(chronos.milliseconds(SlowDelay))
  elif input.startsWith("edge:"):
    await sleepAsync(chronos.milliseconds(EdgeDelay))
  elif input == "block":
    sleep(BlockDelay)
  ok(SlotReq(echoed: input))

# ── Cross-thread coordination (no closures in {.thread.} procs) ───────────

var gDone: Atomic[bool]
var gReuseOk: Atomic[bool]
var gSyncRecovered: Atomic[int]
var gTimedOut: Atomic[bool]
var gProviderReady: Atomic[bool]
var gStopProvider: Atomic[bool]

proc burstOfThree(round: int): Future[bool] {.async: (raises: []).} =
  ## Three concurrent requests against a two-slot pool. A correct pool hands
  ## out at most two slots, so one request must fail with
  ## "response slot pool exhausted" — that is a legal outcome. What is never
  ## legal is a *third* slot appearing out of nowhere: a phantom free-list
  ## entry (from a slot released twice) lets two in-flight requests share one
  ## slot, and the loser reads the winner's payload. Crossed payloads are the
  ## assertion.
  let want1 = "A" & $round
  let want2 = "B" & $round
  let want3 = "C" & $round
  let f1 = SlotReq.request(want1)
  let f2 = SlotReq.request(want2)
  let f3 = SlotReq.request(want3)
  let r1 = await f1
  let r2 = await f2
  let r3 = await f3
  if r1.isOk() and r1.value.echoed != want1:
    return false
  if r2.isOk() and r2.value.echoed != want2:
    return false
  if r3.isOk() and r3.value.echoed != want3:
    return false
  true

proc requesterReuse() {.thread.} =
  let slow = waitFor SlotReq.request("slow:one")
  doAssert slow.isErr(), "slow request should have timed out"
  doAssert "timed out" in slow.error, slow.error

  # Let the provider's late reply land and release the slot, so the next
  # claim recycles that exact index.
  sleep(SlowDelay + 300)

  var allOk = true
  for round in 0 ..< 6:
    if not waitFor burstOfThree(round):
      allOk = false

  for i in 0 ..< 8:
    let want = "seq-" & $i
    let r = waitFor SlotReq.request(want)
    if r.isErr() or r.value.echoed != want:
      allOk = false

  gReuseOk.store(allOk)
  gDone.store(true)

proc requesterEdgeSync() {.thread.} =
  ## Blocking path: the provider replies at (approximately) the deadline, so
  ## iterations land on either side of the give-up race — sometimes the
  ## requester abandons an untouched slot, sometimes it catches the provider
  ## already writing, sometimes the reply beats it by a hair.
  ##
  ## Transient "response slot pool exhausted" here is *legal* and deliberately
  ## not asserted on: an abandoned slot stays claimed until the provider gets
  ## round to replying, so with a 2-slot pool a slow provider can legitimately
  ## hold both. The invariant that matters is that every slot comes *back*:
  ## after the storm settles, the pool must be whole again, which the caller
  ## checks by filling it completely.
  for i in 0 ..< 400:
    discard SlotReq.blockingRequest("edge:" & $i)
  # Let every abandoned slot's provider finish and release it.
  sleep(200)
  var recovered = 0
  for i in 0 ..< 2:
    let r = SlotReq.blockingRequest("settled-" & $i)
    if r.isOk() and r.value.echoed == "settled-" & $i:
      inc recovered
  gSyncRecovered.store(recovered)
  gDone.store(true)

proc requesterQueuedTimeout() {.thread.} =
  ## The first request stalls the provider's event loop, so the second one sits
  ## in the ring. Its (short) timeout expires while it is still queued — and a
  ## request nobody is waiting for any more must be dropped at the consumer,
  ## not executed once the provider comes back.
  let blockFut = SlotReq.request("block")
  sleep(80) # let "block" reach the provider and start stalling it
  let queued = waitFor SlotReq.request("queued:one")
  doAssert queued.isErr(), "queued request should have timed out"
  doAssert "timed out" in queued.error, queued.error
  # Wait out the stall plus the provider's chance to pick the request up.
  sleep(BlockDelay + 300)
  discard waitFor blockFut
  gDone.store(true)

proc providerThreadProc() {.thread.} =
  doAssert SlotReq.setProvider(slotProvider).isOk()
  gProviderReady.store(true)
  while not gStopProvider.load():
    waitFor sleepAsync(chronos.milliseconds(10))
  SlotReq.clearProvider()
  # Give the poll fn a chance to observe the closed ring and queue the
  # (ring, slab, pool) triple; returning from this proc runs
  # teardownBrokerThread, which frees it.
  waitFor sleepAsync(chronos.milliseconds(50))

proc requesterOutlivesPool() {.thread.} =
  let r = waitFor SlotReq.request("slow:uaf")
  doAssert r.isErr(), "request should have timed out"
  gTimedOut.store(true)
  # Keep this thread's dispatcher draining while the provider thread clears
  # its bucket and exits (which frees the pool). Firing our own broker signal
  # forces a drain pass, so any poller still registered here runs — and, if it
  # is still holding the freed pool pointer, dereferences it.
  for _ in 0 ..< 60:
    fireBrokerSignal(getOrInitBrokerSignal())
    waitFor sleepAsync(chronos.milliseconds(20))
  gDone.store(true)

suite "MT RequestBroker — response slot lifecycle":
  asyncTest "timed-out request does not corrupt slot reuse":
    SlotReq.setRequestTimeout(chronos.milliseconds(200))
    check SlotReq.setProvider(slotProvider).isOk()

    gDone.store(false)
    gReuseOk.store(false)
    var th: Thread[void]
    th.createThread(requesterReuse)
    while not gDone.load():
      await sleepAsync(chronos.milliseconds(10))
    th.joinThread()

    check gReuseOk.load()

    SlotReq.clearProvider()
    SlotReq.setRequestTimeout(chronos.seconds(20))

  asyncTest "late replies on the blocking path give every slot back":
    SlotReq.setRequestTimeout(chronos.milliseconds(EdgeDelay))
    check SlotReq.setProvider(slotProvider).isOk()

    gDone.store(false)
    gSyncRecovered.store(0)
    var th: Thread[void]
    th.createThread(requesterEdgeSync)
    while not gDone.load():
      await sleepAsync(chronos.milliseconds(10))
    th.joinThread()

    # Both slots served a request again once things settled: nothing was lost
    # to a give-up that raced the provider's write.
    check gSyncRecovered.load() == 2

    SlotReq.clearProvider()
    SlotReq.setRequestTimeout(chronos.seconds(20))

  asyncTest "a request that times out while queued is never executed":
    SlotReq.setRequestTimeout(chronos.milliseconds(150))
    check SlotReq.setProvider(slotProvider).isOk()

    gDone.store(false)
    gQueuedInvoked.store(false)
    var th: Thread[void]
    th.createThread(requesterQueuedTimeout)
    while not gDone.load():
      await sleepAsync(chronos.milliseconds(10))
    th.joinThread()

    check not gQueuedInvoked.load()

    SlotReq.clearProvider()
    SlotReq.setRequestTimeout(chronos.seconds(20))

  test "no poller outlives the response slot pool":
    SlotReq.setRequestTimeout(chronos.milliseconds(200))

    gDone.store(false)
    gTimedOut.store(false)
    gProviderReady.store(false)
    gStopProvider.store(false)

    var provThread: Thread[void]
    provThread.createThread(providerThreadProc)
    while not gProviderReady.load():
      sleep(5)

    var reqThread: Thread[void]
    reqThread.createThread(requesterOutlivesPool)
    while not gTimedOut.load():
      sleep(5)

    # Tear the provider (and its pool) down while the requester thread keeps
    # draining its pollers.
    gStopProvider.store(true)
    provThread.joinThread()

    while not gDone.load():
      sleep(5)
    reqThread.joinThread()

    SlotReq.setRequestTimeout(chronos.seconds(20))
