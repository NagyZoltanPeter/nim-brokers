## Phase 0 probe (variant 2): does the REDESIGN's actual workload pattern
## stay §2.6-safe?
##
## Workload modeled:
##   - main thread allocates the slab (createShared) — this is the
##     persistent bucket-owning thread.
##   - sender threads claim cells via atomics, write payload bytes, push.
##     They NEVER call allocShared/deallocShared themselves.
##   - sender threads exit (the trigger for §2.6 in the channel-based design).
##   - consumer (main thread) reads from cells via atomics, "releases" them
##     back to a free-list (atomic only).
##   - main thread later allocates new sender threads which claim cells
##     previously released, exercising the free-list across exited-thread
##     boundaries.
##   - eventually main thread deallocShareds the slab.
##
## If this passes under ASAN+ORC+macOS arm64, the redesign is sound:
## same-thread alloc+dealloc of the backing memory, cross-thread atomic
## use of pre-allocated cells, no per-send allocator traffic.

import std/[atomics, os]

const cellSize = 256
const nCells = 64
const nProducerThreads = 16
const nSendsPerThread = 1000

type Cell {.packed.} = object
  inUse: Atomic[bool]
  payload: array[cellSize - sizeof(Atomic[bool]), byte]

var slab: ptr UncheckedArray[Cell]
var totalSends: Atomic[int]

proc claimCell(): int =
  ## Linear scan claim (deliberately simple — just exercising memory layout,
  ## not optimising for hot path). Returns index, or -1 if full.
  for tries in 0 ..< 10:
    for i in 0 ..< nCells:
      var expected = false
      if slab[i].inUse.compareExchange(expected, true, moAcquireRelease):
        return i
    sleep(0)
  return -1

proc releaseCell(idx: int) =
  slab[idx].inUse.store(false, moRelease)

proc producer() {.thread.} =
  ## Sender pattern: claim cell, write payload, "publish" (touch
  ## payload), release. Mirrors what a Tier-A inline payload write
  ## looks like in the redesign — pure atomic + memcpy, no allocator
  ## call from this thread.
  for n in 0 ..< nSendsPerThread:
    let idx = claimCell()
    if idx < 0:
      continue
    for j in 0 ..< sizeof(slab[idx].payload):
      slab[idx].payload[j] = byte((n + j) and 0xff)
    # Simulated consumer-side: a real consumer would read here and then
    # release. We release immediately so the slab doesn't saturate.
    releaseCell(idx)
    discard totalSends.fetchAdd(1, moRelaxed)

proc runRound(roundIdx: int) =
  echo "round ", roundIdx, " — spawning ", nProducerThreads, " producers"
  var threads: array[nProducerThreads, Thread[void]]
  for i in 0 ..< nProducerThreads:
    threads[i].createThread(producer)
  for i in 0 ..< nProducerThreads:
    threads[i].joinThread()
  # All sender threads now exited → their TLV blocks freed on macOS.
  # The slab itself is still alive; main is about to spawn another batch.

proc run() =
  totalSends.store(0)
  # Main allocates the slab (persistent owner thread).
  slab = cast[ptr UncheckedArray[Cell]](createShared(Cell, nCells))
  doAssert not slab.isNil
  for i in 0 ..< nCells:
    slab[i].inUse.store(false)

  # Multiple rounds of spawn → use → exit. Each round retires N sender
  # threads while the slab survives, mirroring what (mt) broker buckets
  # see across scenarios.
  for round in 0 ..< 8:
    runRound(round)

  echo "total sends: ", totalSends.load()
  # Main deallocates the slab (same thread that allocated it).
  deallocShared(slab)
  slab = nil
  echo "PROBE OK — slab workload pattern is §2.6-safe under ASAN+ORC+macOS"

run()
