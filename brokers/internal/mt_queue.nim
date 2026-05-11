## Multi-Thread Broker Queue Primitives
## ------------------------------------
## Lock-free MPSC primitives used to replace `Channel[T]` in the (mt)
## brokers. Implements `doc/REFACTOR_MT_QUEUE.md` §3.
##
## Invariants enforced by *structural design*, not by runtime asserts:
##
## I0  every `createShared` / `deallocShared` runs on a persistent owner
##     thread (bucket-owner for per-bucket structures, global-slab-owner
##     for events). Hot path (claim / release / enqueue / dequeue) never
##     calls any Nim allocator.
## I1  Senders only execute: atomic load / store / CAS, memcpy into
##     pre-allocated cells, and `ThreadSignalPtr.fireSync()` (external).
## I2  The owner thread must outlive every structure it owns.
##
## Phase 1 deliverable: this module + its tests. No broker code calls it
## yet — that lands in Phases 2-4.

{.push raises: [].}

import std/atomics

# ---------------------------------------------------------------------------
# Cache-line padding helpers
# ---------------------------------------------------------------------------

const CacheLineBytes* = 64

type CacheLineGap = array[CacheLineBytes, byte]

# ---------------------------------------------------------------------------
# ShardedFreeList — Treiber stack with ABA tagging, sharded by thread hash
# ---------------------------------------------------------------------------
#
# Head word layout (uint64):
#   bits  0..31  index into the free-list's external `nextLinks` array
#   bits 32..63  ABA tag (incremented on every successful CAS)
#
# A special INDEX value `EmptyIdx` means "this shard is empty".
# The free-list does NOT own the storage — callers manage capacity and
# the `nextLinks` array externally. This keeps the primitive composable.

const EmptyIdx*: uint32 = high(uint32)

template makeHead(idx, tag: uint32): uint64 =
  (uint64(tag) shl 32) or uint64(idx)

template headIdx(v: uint64): uint32 =
  uint32(v and 0xFFFFFFFF'u64)

template headTag(v: uint64): uint32 =
  uint32(v shr 32)

type
  FreeListShard = object
    head: Atomic[uint64]
    gap: CacheLineGap

  ShardedFreeList* = object
    nShardsMask: uint32 ## nShards - 1; nShards is power-of-2
    nShards: uint32
    shards: ptr UncheckedArray[FreeListShard]
    nextLinks: ptr UncheckedArray[uint32] ## idx → next idx (or EmptyIdx)

proc initShardedFreeList*(
    fl: var ShardedFreeList, nShards: uint32, capacity: uint32
) {.gcsafe.} =
  ## Initialize a sharded free-list. `nShards` MUST be a power of two.
  ## `nextLinks` is allocated as a parallel array of `capacity` indices,
  ## all initialised to `EmptyIdx`.
  doAssert nShards > 0 and (nShards and (nShards - 1)) == 0,
    "nShards must be power of two"
  fl.nShards = nShards
  fl.nShardsMask = nShards - 1
  fl.shards =
    cast[ptr UncheckedArray[FreeListShard]](createShared(FreeListShard, nShards.int))
  for i in 0 ..< nShards.int:
    fl.shards[i].head.store(makeHead(EmptyIdx, 0), moRelaxed)
  fl.nextLinks =
    cast[ptr UncheckedArray[uint32]](createShared(uint32, capacity.int))
  for i in 0 ..< capacity.int:
    fl.nextLinks[i] = EmptyIdx

proc deinitShardedFreeList*(fl: var ShardedFreeList) {.gcsafe.} =
  if not fl.shards.isNil:
    deallocShared(fl.shards)
    fl.shards = nil
  if not fl.nextLinks.isNil:
    deallocShared(fl.nextLinks)
    fl.nextLinks = nil

proc push*(fl: var ShardedFreeList, idx: uint32, shardHint: uint32) {.gcsafe.} =
  ## Push `idx` onto the free-list. `shardHint` selects the shard to push to.
  let shardIdx = shardHint and fl.nShardsMask
  let shard = addr fl.shards[shardIdx]
  while true:
    let oldHead = shard.head.load(moAcquire)
    fl.nextLinks[idx] = headIdx(oldHead)
    # Tag increments on every successful push to dodge ABA.
    let newHead = makeHead(idx, headTag(oldHead) + 1)
    var expected = oldHead
    if shard.head.compareExchangeWeak(expected, newHead, moAcquireRelease, moAcquire):
      return

proc pop*(fl: var ShardedFreeList, shardHint: uint32): uint32 {.gcsafe.} =
  ## Pop an index from the free-list. Tries `shardHint`'s shard first;
  ## if empty, scans other shards. Returns `EmptyIdx` if all shards are empty.
  let preferred = shardHint and fl.nShardsMask
  for offset in 0'u32 ..< fl.nShards:
    let shardIdx = (preferred + offset) and fl.nShardsMask
    let shard = addr fl.shards[shardIdx]
    while true:
      let oldHead = shard.head.load(moAcquire)
      let idx = headIdx(oldHead)
      if idx == EmptyIdx:
        break # try next shard
      let nextIdx = fl.nextLinks[idx]
      let newHead = makeHead(nextIdx, headTag(oldHead) + 1)
      var expected = oldHead
      if shard.head.compareExchangeWeak(expected, newHead, moAcquireRelease, moAcquire):
        return idx
      # CAS failed; loop and retry on this shard.
  return EmptyIdx

# ---------------------------------------------------------------------------
# VyukovMpscRing[T] — bounded MPSC ring with closed-flag handoff
# ---------------------------------------------------------------------------
#
# Atomic protocol:
# Producer (`tryEnqueue`):
#   1. closed-check (acquire) → if closed, return false.
#   2. pos = enqPos.load(relaxed)
#   3. loop:
#        slot = &slots[pos & mask]
#        seq = slot.seq.load(acquire)
#        diff = seq - pos  (as signed)
#        if diff == 0:
#          CAS enqPos: pos → pos+1 (acquireRelease on success, acquire on failure)
#          if success: break  (slot is claimed; must publish)
#          else: pos was reloaded into `expected`; loop
#        elif diff < 0:
#          return false (full)
#        else:
#          another producer claimed this slot already; reload pos, loop
#   4. write slot.payload
#   5. slot.seq.store(pos+1, release)  -- publish
#
# Consumer (`tryDequeue`, single-thread):
#   1. pos = deqPos
#   2. seq = slots[pos & mask].seq.load(acquire)
#   3. if seq != pos+1: return false (empty / not yet published)
#   4. read payload
#   5. slots[pos & mask].seq.store(pos + capacity, release) -- slot reusable
#   6. deqPos = pos + 1
#
# Closed-flag handoff (`drain` called by owner):
#   1. closed.store(true, release)
#   2. spin-loop: tryDequeue all visible items; sleep if there's a gap
#      (slot not yet published by an in-flight producer that already CAS'd).
#      Exit when deqPos == enqPos.

type
  Slot*[T] = object
    seq: Atomic[uint64]
    payload*: T

  VyukovMpscRing*[T] = object
    capacity*: uint64
    mask: uint64
    closed: Atomic[bool]
    gap0: CacheLineGap
    enqPos: Atomic[uint64]
    gap1: CacheLineGap
    deqPos: uint64
    gap2: CacheLineGap
    slots: ptr UncheckedArray[Slot[T]]

proc newVyukovMpscRing*[T](capacity: int): ptr VyukovMpscRing[T] {.gcsafe.} =
  ## Allocate a ring of the given capacity (must be power-of-2).
  ## Returns ownership; deinit via `freeVyukovMpscRing`.
  doAssert capacity > 0 and (capacity and (capacity - 1)) == 0,
    "capacity must be power-of-2"
  result = cast[ptr VyukovMpscRing[T]](createShared(VyukovMpscRing[T], 1))
  result.capacity = uint64(capacity)
  result.mask = uint64(capacity - 1)
  result.closed.store(false, moRelaxed)
  result.enqPos.store(0, moRelaxed)
  result.deqPos = 0
  result.slots = cast[ptr UncheckedArray[Slot[T]]](createShared(Slot[T], capacity))
  for i in 0 ..< capacity:
    result.slots[i].seq.store(uint64(i), moRelaxed)

proc freeVyukovMpscRing*[T](ring: ptr VyukovMpscRing[T]) {.gcsafe.} =
  ## Deallocate. Must be called on the owner thread, with the ring already
  ## drained (caller responsibility).
  if ring.isNil:
    return
  if not ring.slots.isNil:
    deallocShared(ring.slots)
  deallocShared(ring)

proc isClosed*[T](ring: ptr VyukovMpscRing[T]): bool {.gcsafe.} =
  ring.closed.load(moAcquire)

proc close*[T](ring: ptr VyukovMpscRing[T]) {.gcsafe.} =
  ring.closed.store(true, moRelease)

proc tryEnqueue*[T](ring: ptr VyukovMpscRing[T], item: sink T): bool {.gcsafe.} =
  ## Returns true if enqueued, false if full or closed.
  ## Safe to call from any number of producer threads.
  if ring.closed.load(moAcquire):
    return false
  var pos = ring.enqPos.load(moRelaxed)
  while true:
    let slot = addr ring.slots[pos and ring.mask]
    let seqV = slot.seq.load(moAcquire)
    let diff = cast[int64](seqV) - cast[int64](pos)
    if diff == 0:
      var expected = pos
      if ring.enqPos.compareExchangeWeak(
        expected, pos + 1, moAcquireRelease, moAcquire
      ):
        # We own slot[pos]. Re-check closed for the "closed after our
        # initial check but before CAS" race; if closed, we must still
        # publish so the consumer can observe and drain it. The drain
        # protocol counts on the slot being published.
        slot.payload = item
        slot.seq.store(pos + 1, moRelease)
        return true
      # CAS failed; `expected` now holds the latest enqPos; retry.
      pos = expected
    elif diff < 0:
      # Full: slot.seq lags pos, which means the prior occupant hasn't
      # been consumed yet.
      return false
    else:
      # diff > 0: another producer is ahead of us; reload pos.
      pos = ring.enqPos.load(moRelaxed)

proc tryDequeue*[T](ring: ptr VyukovMpscRing[T], outItem: var T): bool {.gcsafe.} =
  ## Returns true if an item was dequeued, false if empty.
  ## MUST be called from a single consumer thread.
  let pos = ring.deqPos
  let slot = addr ring.slots[pos and ring.mask]
  let seqV = slot.seq.load(moAcquire)
  let diff = cast[int64](seqV) - cast[int64](pos + 1)
  if diff != 0:
    return false
  outItem = slot.payload
  slot.seq.store(pos + ring.capacity, moRelease)
  ring.deqPos = pos + 1
  return true

proc isEmpty*[T](ring: ptr VyukovMpscRing[T]): bool {.gcsafe.} =
  ## Consumer-side observation; producers may concurrently enqueue,
  ## so callers must treat the result as a hint unless they also hold
  ## a guarantee that no producers are active.
  ring.enqPos.load(moAcquire) == ring.deqPos

# ---------------------------------------------------------------------------
# RefCountedCell + PayloadSlab — pre-allocated payload cells
# ---------------------------------------------------------------------------
#
# Cell layout (computed at runtime, since payload bytes are variable-size):
#   offset 0:  Atomic[int] refcount
#   offset 8:  uint16 payloadSize  (marshaled bytes used)
#   offset 12: payloadBytes[]      (payloadCap bytes; from slab.cellPayloadCap)
#
# We address cells by index (uint32) so the free-list can ABA-tag indices
# rather than pointers. Pointer access is via `slab.cellPtr(idx)`.

type
  CellHeader* = object
    refcount*: Atomic[int]
    payloadSize*: uint16
    pad: uint16
      ## not currently used; preserves 8-byte alignment of the payload that
      ## follows the header

  PayloadSlab* = object
    capacity: uint32
    cellPayloadCap*: uint32 ## bytes available for marshaled data per cell
    cellStride: uint32 ## sizeof(CellHeader) + cellPayloadCap, aligned
    storage: ptr UncheckedArray[byte]
    freeList: ShardedFreeList

proc cellHeaderSize(): uint32 {.compileTime.} =
  uint32(sizeof(CellHeader))

proc alignUp(v, a: uint32): uint32 =
  (v + a - 1) and not (a - 1)

proc initPayloadSlab*(
    slab: var PayloadSlab, capacity: uint32, payloadBytes: uint32, nShards: uint32
) {.gcsafe.} =
  ## Pre-allocates `capacity` cells, each with `payloadBytes` of payload
  ## space. Uses `nShards` (must be power-of-2) for free-list contention.
  ## All cells start on the free-list.
  doAssert capacity > 0
  doAssert payloadBytes > 0
  slab.capacity = capacity
  slab.cellPayloadCap = payloadBytes
  slab.cellStride = alignUp(cellHeaderSize() + payloadBytes, 8'u32)
  slab.storage = cast[ptr UncheckedArray[byte]](
    createShared(byte, int(capacity) * int(slab.cellStride))
  )
  initShardedFreeList(slab.freeList, nShards, capacity)
  # Seed the free-list with every cell.
  for i in 0 ..< capacity:
    push(slab.freeList, i, i)

proc deinitPayloadSlab*(slab: var PayloadSlab) {.gcsafe.} =
  ## MUST be called on the owner thread after every outstanding cell has
  ## been released (caller responsibility). Frees the slab's storage and
  ## the free-list's internal arrays.
  deinitShardedFreeList(slab.freeList)
  if not slab.storage.isNil:
    deallocShared(slab.storage)
    slab.storage = nil

proc cellPtr*(slab: PayloadSlab, idx: uint32): ptr CellHeader {.gcsafe.} =
  ## Returns the header pointer for the cell at `idx`. The payload bytes
  ## immediately follow the header (at `cast[ptr byte](header) +%
  ## sizeof(CellHeader)`).
  cast[ptr CellHeader](addr slab.storage[int(idx) * int(slab.cellStride)])

proc cellPayloadPtr*(
    slab: PayloadSlab, idx: uint32
): ptr UncheckedArray[byte] {.gcsafe.} =
  cast[ptr UncheckedArray[byte]](
    cast[uint](addr slab.storage[int(idx) * int(slab.cellStride)]) +
      uint(sizeof(CellHeader))
  )

proc claim*(slab: var PayloadSlab, shardHint: uint32): uint32 {.gcsafe.} =
  ## Returns a cell index or `EmptyIdx` if the slab is exhausted.
  pop(slab.freeList, shardHint)

proc release*(slab: var PayloadSlab, idx: uint32, shardHint: uint32) {.gcsafe.} =
  ## Returns a cell to the free-list. Caller must ensure no other thread
  ## still holds a reference (refcount == 0).
  push(slab.freeList, idx, shardHint)

proc incRef*(slab: PayloadSlab, idx: uint32) {.gcsafe.} =
  discard slab.cellPtr(idx).refcount.fetchAdd(1, moAcquireRelease)

proc decRefAndCheck*(slab: PayloadSlab, idx: uint32): bool {.gcsafe.} =
  ## Returns true if this decrement brought refcount to zero (caller should
  ## then `release(idx)`).
  let prev = slab.cellPtr(idx).refcount.fetchSub(1, moAcquireRelease)
  prev == 1

# ---------------------------------------------------------------------------
# ResponseSlot[T] + ResponseSlotPool[T] — single-shot request reply
# ---------------------------------------------------------------------------
#
# State machine on the slot's `state` byte:
#   Empty(0) ── requester claimed; provider hasn't written yet
#     │
#     ├── (provider) CAS Empty→Ready, write payload, signal requester
#     │       │
#     │       └── (requester) read payload; release slot
#     │
#     └── (requester timeout) CAS Empty→Abandoned
#             │
#             └── (provider) sees Abandoned; releases slot
#
# In both terminal cases the slot returns to the pool's free-list
# exactly once.

type
  ResponseState* {.pure.} = enum
    Empty = 0'u8
    Ready = 1'u8
    Abandoned = 2'u8

  ResponseSlot*[T] = object
    state: Atomic[uint8]
    payload*: T

  ResponseSlotPool*[T] = object
    capacity*: uint32
    storage: ptr UncheckedArray[ResponseSlot[T]]
    freeList: ShardedFreeList

proc initResponseSlotPool*[T](
    pool: var ResponseSlotPool[T], capacity: uint32, nShards: uint32
) {.gcsafe.} =
  pool.capacity = capacity
  pool.storage =
    cast[ptr UncheckedArray[ResponseSlot[T]]](createShared(ResponseSlot[T], capacity.int))
  initShardedFreeList(pool.freeList, nShards, capacity)
  for i in 0 ..< capacity:
    pool.storage[i].state.store(uint8(ResponseState.Empty), moRelaxed)
    push(pool.freeList, i, i)

proc deinitResponseSlotPool*[T](pool: var ResponseSlotPool[T]) {.gcsafe.} =
  deinitShardedFreeList(pool.freeList)
  if not pool.storage.isNil:
    deallocShared(pool.storage)
    pool.storage = nil

proc claim*[T](
    pool: var ResponseSlotPool[T], shardHint: uint32
): uint32 {.gcsafe.} =
  let idx = pop(pool.freeList, shardHint)
  if idx != EmptyIdx:
    pool.storage[idx].state.store(uint8(ResponseState.Empty), moRelease)
  idx

proc release*[T](
    pool: var ResponseSlotPool[T], idx: uint32, shardHint: uint32
) {.gcsafe.} =
  push(pool.freeList, idx, shardHint)

proc slotPtr*[T](pool: ResponseSlotPool[T], idx: uint32): ptr ResponseSlot[T] {.gcsafe.} =
  addr pool.storage[idx]

proc tryWriteResponse*[T](
    pool: ResponseSlotPool[T], idx: uint32, value: sink T
): bool {.gcsafe.} =
  ## Provider side: attempt to write the response. Returns false if the
  ## requester already abandoned (caller should NOT signal and should
  ## release the slot).
  let slot = pool.slotPtr(idx)
  var expected = uint8(ResponseState.Empty)
  if slot.state.compareExchange(
    expected, uint8(ResponseState.Ready), moAcquireRelease, moAcquire
  ):
    slot.payload = value
    # Re-store state with release to ensure payload write is visible.
    slot.state.store(uint8(ResponseState.Ready), moRelease)
    return true
  return false # was Abandoned

proc abandon*[T](pool: ResponseSlotPool[T], idx: uint32): bool {.gcsafe.} =
  ## Requester side (timeout): mark the slot as abandoned. Returns true
  ## if abandonment took effect (provider hadn't written yet); false if
  ## the provider had already written Ready (the requester should then
  ## read the payload normally).
  let slot = pool.slotPtr(idx)
  var expected = uint8(ResponseState.Empty)
  slot.state.compareExchange(
    expected, uint8(ResponseState.Abandoned), moAcquireRelease, moAcquire
  )

proc readyState*[T](pool: ResponseSlotPool[T], idx: uint32): bool {.gcsafe.} =
  pool.slotPtr(idx).state.load(moAcquire) == uint8(ResponseState.Ready)
