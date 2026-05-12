## Phase 1 tests for `brokers/internal/mt_queue.nim`.
##
## Validates the primitives against:
##   - basic single-thread correctness;
##   - cross-thread stress (under ASAN+orc and ASAN+refc on macOS arm64);
##   - the §2.6 structural invariant — sender threads exit during the
##     test; we verify post-exit operations (drain, release, decRef) are
##     still safe because the slab/ring memory is owned by main.

{.used.}

import std/[atomics, os, sets]
import testutils/unittests

import brokers/internal/mt_queue

# ───────────────────────────────────────────────────────────────────────────
# VyukovMpscRing
# ───────────────────────────────────────────────────────────────────────────

suite "VyukovMpscRing — basics":
  test "single-producer single-consumer FIFO":
    let ring = newVyukovMpscRing[int](16)
    for i in 0 ..< 16:
      check ring.tryEnqueue(i)
    # 17th should fail — full
    check (not ring.tryEnqueue(99))
    var x: int
    for i in 0 ..< 16:
      check ring.tryDequeue(x)
      check x == i
    check (not ring.tryDequeue(x))
    check ring.isEmpty()
    freeVyukovMpscRing(ring)

  test "interleaved push/pop":
    let ring = newVyukovMpscRing[int](4)
    var x: int
    check ring.tryEnqueue(1)
    check ring.tryEnqueue(2)
    check ring.tryDequeue(x); check x == 1
    check ring.tryEnqueue(3)
    check ring.tryEnqueue(4)
    check ring.tryEnqueue(5)
    check (not ring.tryEnqueue(6)) # full
    check ring.tryDequeue(x); check x == 2
    check ring.tryDequeue(x); check x == 3
    check ring.tryDequeue(x); check x == 4
    check ring.tryDequeue(x); check x == 5
    check (not ring.tryDequeue(x))
    freeVyukovMpscRing(ring)

  test "closed flag rejects new enqueues":
    let ring = newVyukovMpscRing[int](8)
    check ring.tryEnqueue(1)
    ring.close()
    check (not ring.tryEnqueue(2))
    var x: int
    check ring.tryDequeue(x); check x == 1
    freeVyukovMpscRing(ring)

# ─── MPSC stress ──────────────────────────────────────────────────────────
#
# 16 producer threads × 10000 enqueues, single consumer (main).  Each
# producer encodes (producerId, sequenceWithinProducer) in a single int.
# Consumer validates per-producer ordering and total count.  Producer
# threads EXIT after producing — this is the §2.6 trigger pattern.

const nProducers = 16
const nMsgsPerProducer = 10_000
const ringCap = 1024 # power-of-2, intentionally smaller than nProducers*nMsgs

type StressShared = object
  ring: ptr VyukovMpscRing[int]
  totalEnqueued: Atomic[int]
  totalRejected: Atomic[int]
  startGate: Atomic[bool]

var stress: StressShared

proc stressProducer(id: int) {.thread.} =
  while not stress.startGate.load(moAcquire):
    sleep(0)
  for n in 0 ..< nMsgsPerProducer:
    let payload = (id shl 20) or n
    var tries = 0
    while not stress.ring.tryEnqueue(payload):
      inc tries
      if tries > 1000:
        discard stress.totalRejected.fetchAdd(1, moRelaxed)
        # Yield and retry; we want zero loss for this test.
        sleep(0)
        tries = 0
    discard stress.totalEnqueued.fetchAdd(1, moRelaxed)

suite "VyukovMpscRing — MPSC stress":
  test "16 producers × 10000 enqueues, no loss, per-producer FIFO":
    stress.ring = newVyukovMpscRing[int](ringCap)
    stress.totalEnqueued.store(0, moRelaxed)
    stress.totalRejected.store(0, moRelaxed)
    stress.startGate.store(false, moRelease)

    var threads: array[nProducers, Thread[int]]
    for i in 0 ..< nProducers:
      threads[i].createThread(stressProducer, i)

    # Release all producers simultaneously.
    stress.startGate.store(true, moRelease)

    # Single consumer (main thread): drain as producers run, then drain
    # again after they exit.
    let total = nProducers * nMsgsPerProducer
    var perProducerLastSeq: array[nProducers, int]
    for i in 0 ..< nProducers:
      perProducerLastSeq[i] = -1
    var consumed = 0
    var emptyChecks = 0
    var x: int
    while consumed < total:
      if stress.ring.tryDequeue(x):
        let id = x shr 20
        let seqN = x and ((1 shl 20) - 1)
        check id >= 0 and id < nProducers
        check seqN == perProducerLastSeq[id] + 1
        perProducerLastSeq[id] = seqN
        inc consumed
        emptyChecks = 0
      else:
        sleep(0)
        inc emptyChecks
        if emptyChecks > 1_000_000:
          # Producer is stuck or test hangs — fail loudly.
          check false # forced fail
          break

    # All producer threads exit *here* (joinThread). After they exit,
    # the ring's slot bytes still reference data they wrote — but our
    # consumer already read everything, and the ring's memory is owned
    # by main. So §2.6's mechanism (sender-thread chunk-metadata) cannot
    # apply: the writes went into pre-allocated slots, not into
    # sender-thread per-thread arenas.
    for i in 0 ..< nProducers:
      threads[i].joinThread()

    check consumed == total
    check stress.ring.isEmpty()
    for i in 0 ..< nProducers:
      check perProducerLastSeq[i] == nMsgsPerProducer - 1

    freeVyukovMpscRing(stress.ring)

# ─── Closed-flag drain handoff ─────────────────────────────────────────────

type DrainShared = object
  ring: ptr VyukovMpscRing[int]
  produced: Atomic[int]
  startGate: Atomic[bool]
  stopFlag: Atomic[bool]

var drainShared: DrainShared

proc drainProducer(id: int) {.thread.} =
  while not drainShared.startGate.load(moAcquire):
    sleep(0)
  var n = 0
  while not drainShared.stopFlag.load(moAcquire):
    if drainShared.ring.tryEnqueue((id shl 20) or n):
      discard drainShared.produced.fetchAdd(1, moRelaxed)
      inc n
    else:
      sleep(0)

suite "VyukovMpscRing — close + drain":
  test "after close, producer fails; consumer drains everything published":
    drainShared.ring = newVyukovMpscRing[int](256)
    drainShared.produced.store(0, moRelaxed)
    drainShared.startGate.store(false, moRelease)
    drainShared.stopFlag.store(false, moRelaxed)

    var threads: array[4, Thread[int]]
    for i in 0 ..< 4:
      threads[i].createThread(drainProducer, i)
    drainShared.startGate.store(true, moRelease)

    # Let producers run briefly.
    sleep(30)
    drainShared.stopFlag.store(true, moRelease)

    # Producers will see stopFlag soon and exit naturally; close the
    # ring concurrently to also reject any laggards.
    drainShared.ring.close()
    for i in 0 ..< 4:
      threads[i].joinThread()

    # Drain.  After producers have all exited, enqPos is stable; the
    # consumer can keep dequeuing until empty.
    var consumed = 0
    var x: int
    while drainShared.ring.tryDequeue(x):
      inc consumed
    check consumed == drainShared.produced.load(moAcquire)

    freeVyukovMpscRing(drainShared.ring)

# ───────────────────────────────────────────────────────────────────────────
# ShardedFreeList
# ───────────────────────────────────────────────────────────────────────────

suite "ShardedFreeList — basics":
  test "push/pop returns LIFO within a shard":
    var fl: ShardedFreeList
    initShardedFreeList(fl, nShards = 1, capacity = 16)
    # Seed: push 0,1,2,3
    push(fl, 0, 0); push(fl, 1, 0); push(fl, 2, 0); push(fl, 3, 0)
    check pop(fl, 0) == 3
    check pop(fl, 0) == 2
    check pop(fl, 0) == 1
    check pop(fl, 0) == 0
    check pop(fl, 0) == EmptyIdx
    deinitShardedFreeList(fl)

  test "empty pop returns EmptyIdx across all shards":
    var fl: ShardedFreeList
    initShardedFreeList(fl, nShards = 4, capacity = 8)
    check pop(fl, 0) == EmptyIdx
    check pop(fl, 1) == EmptyIdx
    check pop(fl, 2) == EmptyIdx
    deinitShardedFreeList(fl)

# Stress: many threads push+pop concurrently.  Verify no idx is lost.
const flCapacity: uint32 = 4096
const flProducerThreads = 8

type FlShared = object
  fl: ShardedFreeList
  popCounts: array[flCapacity.int, Atomic[int]]
  startGate: Atomic[bool]

var flShared: FlShared

proc flStressWorker(id: int) {.thread.} =
  while not flShared.startGate.load(moAcquire):
    sleep(0)
  # Each worker repeatedly pops and pushes; over many iterations we
  # verify cumulative invariants.
  for round in 0 ..< 1000:
    let idx = pop(flShared.fl, uint32(id))
    if idx == EmptyIdx:
      continue
    discard flShared.popCounts[idx.int].fetchAdd(1, moRelaxed)
    push(flShared.fl, idx, uint32(id))

suite "ShardedFreeList — concurrency":
  test "8 threads × 1000 pop/push round-trips, no index leaks":
    initShardedFreeList(flShared.fl, nShards = 4, capacity = flCapacity)
    for i in 0 ..< flCapacity:
      push(flShared.fl, i, i)
      flShared.popCounts[i.int].store(0, moRelaxed)
    flShared.startGate.store(false, moRelease)

    var threads: array[flProducerThreads, Thread[int]]
    for i in 0 ..< flProducerThreads:
      threads[i].createThread(flStressWorker, i)
    flShared.startGate.store(true, moRelease)
    for i in 0 ..< flProducerThreads:
      threads[i].joinThread()

    # Every idx must still be poppable (the free-list should hold all
    # `capacity` indices since every pop was paired with a push).
    var seen = initHashSet[uint32]()
    while true:
      let idx = pop(flShared.fl, 0)
      if idx == EmptyIdx: break
      check (idx notin seen)
      seen.incl(idx)
    check seen.len == flCapacity.int

    deinitShardedFreeList(flShared.fl)

# ───────────────────────────────────────────────────────────────────────────
# PayloadSlab
# ───────────────────────────────────────────────────────────────────────────

suite "PayloadSlab — basics":
  test "claim + release single-threaded":
    var slab: PayloadSlab
    initPayloadSlab(slab, capacity = 8, payloadBytes = 64, nShards = 1)
    let a = slab.claim(0)
    let b = slab.claim(0)
    check a != EmptyIdx and b != EmptyIdx and a != b
    # Write payload bytes for a:
    let pa = slab.cellPayloadPtr(a)
    pa[0] = 0xAA'u8
    pa[63] = 0xBB'u8
    check pa[0] == 0xAA'u8
    check pa[63] == 0xBB'u8
    slab.release(a, 0)
    slab.release(b, 0)
    deinitPayloadSlab(slab)

  test "exhaust + drain":
    var slab: PayloadSlab
    initPayloadSlab(slab, capacity = 4, payloadBytes = 8, nShards = 1)
    var indices: array[4, uint32]
    for i in 0 ..< 4:
      indices[i] = slab.claim(0)
      check indices[i] != EmptyIdx
    check slab.claim(0) == EmptyIdx # exhausted
    for i in 0 ..< 4:
      slab.release(indices[i], 0)
    # Now claim should succeed again
    check slab.claim(0) != EmptyIdx
    deinitPayloadSlab(slab)

# ─── Refcount race ────────────────────────────────────────────────────────

const refRaceWorkers = 16

type RefRaceShared = object
  slab: PayloadSlab
  cellIdx: uint32
  zeroObservers: Atomic[int]
  startGate: Atomic[bool]

var refRace: RefRaceShared

proc refRaceWorker(id: int) {.thread.} =
  while not refRace.startGate.load(moAcquire):
    sleep(0)
  if refRace.slab.decRefAndCheck(refRace.cellIdx):
    discard refRace.zeroObservers.fetchAdd(1, moRelaxed)

suite "PayloadSlab — refcount race":
  test "16 threads decRef same cell — exactly one observer sees zero":
    initPayloadSlab(refRace.slab, capacity = 8, payloadBytes = 8, nShards = 1)
    refRace.cellIdx = refRace.slab.claim(0)
    refRace.slab.cellPtr(refRace.cellIdx).refcount.store(refRaceWorkers, moRelease)
    refRace.zeroObservers.store(0, moRelaxed)
    refRace.startGate.store(false, moRelease)

    var threads: array[refRaceWorkers, Thread[int]]
    for i in 0 ..< refRaceWorkers:
      threads[i].createThread(refRaceWorker, i)
    refRace.startGate.store(true, moRelease)
    for i in 0 ..< refRaceWorkers:
      threads[i].joinThread()

    check refRace.zeroObservers.load(moAcquire) == 1
    check refRace.slab.cellPtr(refRace.cellIdx).refcount.load(moAcquire) == 0
    refRace.slab.release(refRace.cellIdx, 0)
    deinitPayloadSlab(refRace.slab)

# ─── §2.6 invariant: producer threads exit, then dealloc on main ──────────

const aliveProducers = 8
const aliveOps = 5000

type AliveShared = object
  ring: ptr VyukovMpscRing[uint32]
  slab: PayloadSlab
  startGate: Atomic[bool]

var alive: AliveShared

proc aliveProducer(id: int) {.thread.} =
  while not alive.startGate.load(moAcquire):
    sleep(0)
  for n in 0 ..< aliveOps:
    let idx = alive.slab.claim(uint32(id))
    if idx == EmptyIdx:
      sleep(0)
      continue
    let p = alive.slab.cellPayloadPtr(idx)
    for j in 0 ..< 8:
      p[j] = byte((id + n + j) and 0xff)
    alive.slab.cellPtr(idx).refcount.store(1, moRelease)
    if not alive.ring.tryEnqueue(idx):
      # Ring full → release the cell instead of pushing.
      alive.slab.release(idx, uint32(id))

suite "mt_queue — §2.6 invariant smoke":
  test "producers exit before main deallocs ring+slab, no UAF":
    alive.ring = newVyukovMpscRing[uint32](256)
    initPayloadSlab(alive.slab, capacity = 512, payloadBytes = 32, nShards = 4)
    alive.startGate.store(false, moRelease)

    var threads: array[aliveProducers, Thread[int]]
    for i in 0 ..< aliveProducers:
      threads[i].createThread(aliveProducer, i)
    alive.startGate.store(true, moRelease)
    for i in 0 ..< aliveProducers:
      threads[i].joinThread()
    # Producer threads have all EXITED here.  Their dyld TLV blocks
    # are now free()'d by _pthread_tsd_cleanup on macOS.  If §2.6
    # applied to our hot path, the next operations would UAF.

    # Drain the ring; release each cell.
    var idx: uint32
    var drained = 0
    while alive.ring.tryDequeue(idx):
      if alive.slab.decRefAndCheck(idx):
        alive.slab.release(idx, 0)
      inc drained
    # Some sends may have been rejected (ring full); just verify the
    # ring is empty now and the slab can fully reclaim.
    check alive.ring.isEmpty()

    freeVyukovMpscRing(alive.ring)
    deinitPayloadSlab(alive.slab)
    echo "drained ", drained, " cells; producers all exited cleanly"

# ───────────────────────────────────────────────────────────────────────────
# ResponseSlotPool
# ───────────────────────────────────────────────────────────────────────────

suite "ResponseSlotPool — basics":
  test "claim + write bytes + commit + release":
    var pool: ResponseSlotPool
    initResponseSlotPool(pool, capacity = 4, maxPayloadBytes = 32, nShards = 1)
    let idx = pool.claim(0)
    check idx != EmptyIdx
    check pool.beginWrite(idx)
    let payload = pool.slotPayloadPtr(idx)
    payload[0] = 42'u8
    payload[1] = 99'u8
    pool.commitWrite(idx, 2'u16)
    check pool.readyState(idx)
    check pool.payloadSize(idx) == 2'u16
    let payload2 = pool.slotPayloadPtr(idx)
    check payload2[0] == 42'u8
    check payload2[1] == 99'u8
    pool.release(idx, 0)
    deinitResponseSlotPool(pool)

  test "abandon prevents subsequent beginWrite":
    var pool: ResponseSlotPool
    initResponseSlotPool(pool, capacity = 4, maxPayloadBytes = 16, nShards = 1)
    let idx = pool.claim(0)
    check pool.abandon(idx)
    check (not pool.beginWrite(idx))
    pool.release(idx, 0)
    deinitResponseSlotPool(pool)

  test "beginWrite then abandon: beginWrite wins":
    var pool: ResponseSlotPool
    initResponseSlotPool(pool, capacity = 4, maxPayloadBytes = 16, nShards = 1)
    let idx = pool.claim(0)
    check pool.beginWrite(idx)
    # abandon after beginWrite should fail (state already Writing, not Empty)
    check (not pool.abandon(idx))
    pool.commitWrite(idx, 0'u16)
    check pool.readyState(idx)
    pool.release(idx, 0)
    deinitResponseSlotPool(pool)

# Race: provider and requester race; verify mutual exclusion semantics.

const respRaceRounds = 200

type RespRaceShared = object
  pool: ResponseSlotPool
  idx: uint32
  outcome: Atomic[int] # 1=write won, 2=abandon won, 0=neither/error
  startGate: Atomic[bool]

var respRace: RespRaceShared

proc respWriter() {.thread.} =
  while not respRace.startGate.load(moAcquire):
    sleep(0)
  if respRace.pool.beginWrite(respRace.idx):
    respRace.pool.commitWrite(respRace.idx, 0'u16)
    var expected = 0
    discard
      respRace.outcome.compareExchange(expected, 1, moAcquireRelease, moAcquire)

proc respAbandoner() {.thread.} =
  while not respRace.startGate.load(moAcquire):
    sleep(0)
  if respRace.pool.abandon(respRace.idx):
    var expected = 0
    discard
      respRace.outcome.compareExchange(expected, 2, moAcquireRelease, moAcquire)

suite "ResponseSlotPool — race":
  test "concurrent write vs abandon — exactly one wins":
    for round in 0 ..< respRaceRounds:
      initResponseSlotPool(
        respRace.pool, capacity = 2, maxPayloadBytes = 16, nShards = 1
      )
      respRace.idx = respRace.pool.claim(0)
      respRace.outcome.store(0, moRelaxed)
      respRace.startGate.store(false, moRelease)

      var tw, ta: Thread[void]
      tw.createThread(respWriter)
      ta.createThread(respAbandoner)
      respRace.startGate.store(true, moRelease)
      tw.joinThread()
      ta.joinThread()

      let outcome = respRace.outcome.load(moAcquire)
      check (outcome == 1 or outcome == 2)
      respRace.pool.release(respRace.idx, 0)
      deinitResponseSlotPool(respRace.pool)
