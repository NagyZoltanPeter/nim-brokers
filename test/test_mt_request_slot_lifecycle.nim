{.used.}

import testutils/unittests
import chronos
import std/[atomics, os, strutils]

import brokers/request_broker
import brokers/internal/mt_broker_common
import brokers/internal/mt_queue

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

proc fillPool(): Future[int] {.async: (raises: []).} =
  ## Two concurrent requests against a two-slot pool: both can only succeed if
  ## *both* slots came back. A sequential probe would be satisfied by one.
  let f1 = SlotReq.request("settled-a")
  let f2 = SlotReq.request("settled-b")
  let r1 = await f1
  let r2 = await f2
  var n = 0
  if r1.isOk() and r1.value.echoed == "settled-a":
    inc n
  if r2.isOk() and r2.value.echoed == "settled-b":
    inc n
  n

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
  # The storm's deadline is deliberately shorter than a round trip; the
  # recovery probe needs an ordinary one, or a loaded machine fails it on
  # timing alone and says nothing about slot bookkeeping.
  SlotReq.setRequestTimeout(chronos.seconds(5))
  # Retry while abandoned slots are still making their way back from lagging
  # providers. A slot that was genuinely lost never returns, so no amount of
  # retrying can paper over a leak.
  var recovered = 0
  for attempt in 0 ..< 20:
    sleep(50)
    recovered = waitFor fillPool()
    if recovered == 2:
      break
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

## ---------------------------------------------------------------------------
## Response-slot state machine — deterministic unit coverage
##
## The end-to-end tests above can only reach the "requester gave up while the
## provider was mid-write" transition by chance: the window between
## `beginWrite` and `commitWrite` is a payload marshal wide, hit in well under
## 1% of timed-out requests. Driving the slot directly pins that contract —
## and the two neighbouring ones — without racing anything.
## ---------------------------------------------------------------------------

suite "MT RequestBroker — response slot ownership":
  test "give-up before the provider starts: provider releases":
    var pool: ResponseSlotPool
    initResponseSlotPool(pool, capacity = 2, maxPayloadBytes = 128, nShards = 1)
    let idx = pool.claim(0)
    let gen = pool.slotGen(idx)

    check pool.giveUpSlot(idx, gen) == SlotGiveUp.ProviderReleases
    # The provider finds the slot abandoned and releases it without writing.
    check pool.beginWrite(idx, gen) == BeginWriteResult.Abandoned
    pool.release(idx, 0)

    check pool.claim(0) != EmptyIdx
    deinitResponseSlotPool(pool)

  test "give-up while the provider is writing: provider still releases":
    var pool: ResponseSlotPool
    initResponseSlotPool(pool, capacity = 2, maxPayloadBytes = 128, nShards = 1)
    let idx = pool.claim(0)
    let gen = pool.slotGen(idx)

    check pool.beginWrite(idx, gen) == BeginWriteResult.Acquired
    check pool.giveUpSlot(idx, gen) == SlotGiveUp.ProviderReleases
    # The provider only learns of it here: the commit must not publish, and the
    # release is the provider's. Reporting success would strand the slot, since
    # the requester has already stopped watching it.
    check pool.commitWrite(idx, gen, 4'u32) == false
    pool.release(idx, 0)

    check pool.claim(0) != EmptyIdx
    deinitResponseSlotPool(pool)

  test "give-up after the response was published: caller releases":
    var pool: ResponseSlotPool
    initResponseSlotPool(pool, capacity = 2, maxPayloadBytes = 128, nShards = 1)
    let idx = pool.claim(0)
    let gen = pool.slotGen(idx)

    check pool.beginWrite(idx, gen) == BeginWriteResult.Acquired
    check pool.commitWrite(idx, gen, 4'u32) == true
    check pool.readyState(idx, gen)
    # Nobody else will touch a published slot, so the giver-up owns it.
    check pool.giveUpSlot(idx, gen) == SlotGiveUp.CallerReleases
    pool.release(idx, 0)

    check pool.claim(0) != EmptyIdx
    deinitResponseSlotPool(pool)

  test "a stale generation acts on nothing":
    var pool: ResponseSlotPool
    initResponseSlotPool(pool, capacity = 1, maxPayloadBytes = 128, nShards = 1)
    let idx = pool.claim(0)
    let staleGen = pool.slotGen(idx)
    pool.release(idx, 0)
    # Same index, new owner.
    let reused = pool.claim(0)
    check reused == idx
    let freshGen = pool.slotGen(reused)
    check freshGen != staleGen

    check pool.giveUpSlot(idx, staleGen) == SlotGiveUp.Stale
    check pool.beginWrite(idx, staleGen) == BeginWriteResult.Stale
    check not pool.readyState(idx, staleGen)
    check not pool.isAbandoned(idx, staleGen)
    # The new owner is untouched.
    check pool.beginWrite(reused, freshGen) == BeginWriteResult.Acquired
    deinitResponseSlotPool(pool)
