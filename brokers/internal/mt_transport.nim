## Multi-Thread Broker Transport
## -----------------------------
## Non-generated runtime shared by the three MT broker macros
## (`mt_request_broker`, `mt_event_broker`, `mt_signal_broker`). It composes
## the primitives of `mt_queue` (ring, slab, response pool) and
## `mt_broker_common` (lease, signal, poller) into the send path every lane
## used to generate its own copy of. The macros keep only what is genuinely
## per type: codecs, threadvars, dispatch and the typed public verbs.
##
## Generic procs here are instantiated in the user's module, where the
## per-type codec overloads (`mtMarshal` / `mtUnmarshal` / `mtMarshalSize`,
## emitted by `genMtCodecProcs`) are visible; they are resolved with `mixin`.
##
## Memory: everything touched here is C heap (`queueAlloc0`, mt_queue I0) or
## plain globals holding no GC refs, so behaviour is identical under
## --mm:refc and --mm:orc. Codec calls stay wrapped in `try/except
## Exception`: the codecs are `raises: []`, but the callers' `raises: []`
## contract must not depend on that.

{.push raises: [].}

import std/[atomics, locks]
import ../broker_context, ../broker_scope
import ./mt_queue, ./mt_broker_common

export mt_queue

# ---------------------------------------------------------------------------
# Free-list shard hint
# ---------------------------------------------------------------------------

proc mtShardHint*(): uint32 {.inline, gcsafe.} =
  ## Hash of the calling thread's TLS marker → free-list shard.
  cast[uint32](cast[uint](currentMtThreadId()) shr 4)

# ---------------------------------------------------------------------------
# Lazily initialised global slab (event / signal lanes)
# ---------------------------------------------------------------------------

type MtLazySlab* = object
  ## A per-broker-type global payload slab, allocated by whichever thread
  ## first needs it and never freed (shared by every bucket of the type).
  slab*: PayloadSlab
  state: Atomic[int] ## 0 = uninitialised, 1 = initialising, 2 = ready

proc ensureInit*(
    s: var MtLazySlab, capacity, payloadBytes, nShards: uint32
) {.gcsafe.} =
  ## CAS(0→1) wins and initialises; losers spin until 2.
  if s.state.load(moRelaxed) == 2:
    return
  var expected = 0
  if s.state.compareExchange(expected, 1, moAcquire, moRelaxed):
    initPayloadSlab(
      s.slab, capacity = capacity, payloadBytes = payloadBytes, nShards = nShards
    )
    s.state.store(2, moRelease)
  else:
    while s.state.load(moAcquire) != 2:
      discard

# ---------------------------------------------------------------------------
# Send path: claim → marshal → heap-spill → refcount → enqueue → wake
# ---------------------------------------------------------------------------

type
  MtSendStatus* = enum
    mssOk
    mssSlabExhausted ## no free cell
    mssTooLarge ## payload over `maxDynamicPayloadBytes` (or unsizable)
    mssSpillFailed ## heap-spill allocation failed
    mssMarshalFailed ## marshal into the spill buffer failed
    mssQueueFull ## target ring full (or closed)

  MtCell* = object
    status*: MtSendStatus
    idx*: uint32 ## claimed cell; `EmptyIdx` unless `status == mssOk`
    needed*: int ## spill size when the payload did not fit inline, else 0

proc releaseCellRef*(slab: var PayloadSlab, idx: uint32) {.inline, gcsafe.} =
  ## Drop one reference to a cell; the last one returns it to the free list.
  if slab.decRefAndCheck(idx):
    slab.release(idx, mtShardHint())

proc claimCell*[T](
    slab: var PayloadSlab, value: T, maxDynPayload: int, refs: int
): MtCell {.inline, gcsafe.} =
  ## Claim a cell and marshal `value` into it, spilling to an exact-size C-heap
  ## buffer when it does not fit inline. On success the cell's refcount is
  ## `refs` (one per ring it will be enqueued on). On failure no cell is held.
  mixin mtMarshal, mtMarshalSize
  let shardHint = mtShardHint()
  let cellIdx = slab.claim(shardHint)
  if cellIdx == EmptyIdx:
    return MtCell(status: mssSlabExhausted, idx: EmptyIdx)
  let cell = slab.cellPtr(cellIdx)
  let written =
    try:
      mtMarshal(slab.cellPayloadPtr(cellIdx), int(slab.cellPayloadCap), value)
    except Exception:
      -1
  if written >= 0:
    cell.payloadSize = uint32(written)
  else:
    # The payload exceeded the fixed cell: marshal into an exact-size heap
    # buffer instead of failing. Owned by the cell; freed at release.
    let needed =
      try:
        mtMarshalSize(value)
      except Exception:
        -1
    if needed < 0 or needed > maxDynPayload:
      slab.release(cellIdx, shardHint)
      return MtCell(status: mssTooLarge, idx: EmptyIdx, needed: needed)
    let spillBuf = queueAlloc0(needed)
    if spillBuf.isNil:
      slab.release(cellIdx, shardHint)
      return MtCell(status: mssSpillFailed, idx: EmptyIdx, needed: needed)
    let w2 =
      try:
        mtMarshal(cast[ptr UncheckedArray[byte]](spillBuf), needed, value)
      except Exception:
        -1
    if w2 < 0:
      queueFree(spillBuf)
      slab.release(cellIdx, shardHint)
      return MtCell(status: mssMarshalFailed, idx: EmptyIdx, needed: needed)
    slab.setOverflow(cellIdx, spillBuf, uint32(w2))
  cell.refcount.store(refs, moRelease)
  MtCell(status: mssOk, idx: cellIdx)

proc sendCell*[T](
    slab: var PayloadSlab,
    ring: ptr VyukovMpscRing[uint32],
    signal: ptr BrokerSignalShared,
    value: T,
    maxDynPayload: int,
): MtSendStatus {.inline, gcsafe.} =
  ## Single-target send: claim + marshal a cell, enqueue it on `ring` and wake
  ## the consumer thread. On any failure nothing stays claimed.
  let c = claimCell(slab, value, maxDynPayload, refs = 1)
  if c.status != mssOk:
    return c.status
  if not ring.tryEnqueue(c.idx):
    releaseCellRef(slab, c.idx)
    return mssQueueFull
  fireBrokerSignal(signal)
  mssOk

# ---------------------------------------------------------------------------
# Receive path: dequeue → closed + empty → unmarshal → release
# ---------------------------------------------------------------------------

type MtPollStep* = enum
  mpsEmpty ## nothing queued; poll fn returns 0
  mpsClosed ## ring closed and drained; the poll fn retires (returns 2)
  mpsSentinel ## a control value (`sentinel`) instead of a cell index
  mpsValue ## `value` holds the decoded payload
  mpsBadValue ## the payload did not unmarshal

proc pollCell*[T](
    ring: ptr VyukovMpscRing[uint32],
    slab: var PayloadSlab,
    value: var T,
    sentinel = EmptyIdx,
): MtPollStep {.inline, gcsafe.} =
  ## One receive step of a broker poll fn. The cell is released (one
  ## reference) before returning: `value` is a copy on this thread's heap.
  ## Dispatching the value stays at the generated call site, which owns the
  ## per-type threadvars and their `{.cast(gcsafe).}`.
  mixin mtUnmarshal
  var cellIdx: uint32
  if not ring.tryDequeue(cellIdx):
    # `closed` is set before the last producer can have enqueued, so closed +
    # empty is the definitive drained point.
    return (if ring.isClosed(): mpsClosed else: mpsEmpty)
  if cellIdx == sentinel:
    return mpsSentinel
  let ok =
    try:
      mtUnmarshal(slab.dataPtr(cellIdx), slab.dataLen(cellIdx), value)
    except Exception:
      false
  releaseCellRef(slab, cellIdx)
  if ok: mpsValue else: mpsBadValue

# ---------------------------------------------------------------------------
# Bucket registry
# ---------------------------------------------------------------------------
# One registry per broker type: a lock-protected, grow-only array of buckets
# in shared memory. A bucket is one (brokerCtx, owning thread) transport
# endpoint. Each lane's generated bucket type embeds an `MtBucketHead` as its
# `head` field (a plain field, not `object of`: no RTTI in shared memory) and
# adds what only it needs (request: slab + response pool).
#
# Lookups that hand transport pointers to another thread take the bucket's
# `BrokerRingLease` reference in the same critical section that found the
# bucket (`snapshot`); the caller drops it with an explicit `release` once its
# last access is done. There is deliberately no `=destroy` guard: an implicit
# destructor on a lease copied into an async environment (refc) is exactly
# the kind of hidden lifetime the lease exists to make visible.

type
  MtBucketHead* = object
    ctx*: BrokerContext
    threadId*: pointer ## `currentMtThreadId()` of the owning thread
    threadGen*: uint64 ## disambiguates reused threadvar addresses
    ring*: ptr VyukovMpscRing[uint32]
    lease*: ptr BrokerRingLease ## owner + in-flight sender refs (frees the ring)
    signal*: ptr BrokerSignalShared ## the owning thread's dispatch signal
    active*: bool ## request: always true; event / signal: bucket is live
    hasListeners*: bool ## event only: the owning thread has >= 1 listener

  MtRegistry*[B] = object
    lock*: Lock
    buckets*: ptr UncheckedArray[B]
    count*: int
    cap: int
    state: Atomic[int] ## 0 = uninitialised, 1 = initialising, 2 = ready

  MtTarget*[B] = object
    ## Result of a locked lookup. `bucket` is a copy, valid (with its lease
    ## reference held) only when `found and not sameThread`.
    found*: bool
    sameThread*: bool
    bucket*: B

  MtSetupPolicy* = enum
    ## What `setupCheck` does when a bucket for the ctx already exists.
    mspOkIfOwned ## request: ok when this thread owns it, else rejected
    mspRejectActive ## signal: any active bucket is a duplicate
    mspReuseOwned ## event: this thread's bucket is re-activated and reused

  MtSetupOutcome* = enum
    msoCreate ## no bucket: the caller builds one and `append`s it
    msoExisting ## reusable bucket owned by this thread
    msoRejected ## owned elsewhere / duplicate

proc isOwnedHere*(h: MtBucketHead): bool {.inline, gcsafe.} =
  h.threadId == currentMtThreadId() and h.threadGen == currentMtThreadGen()

proc initHead*(
    ctx: BrokerContext, ring: ptr VyukovMpscRing[uint32], lease: ptr BrokerRingLease
): MtBucketHead {.gcsafe.} =
  ## Head for a bucket owned by the calling thread.
  MtBucketHead(
    ctx: ctx,
    threadId: currentMtThreadId(),
    threadGen: currentMtThreadGen(),
    ring: ring,
    lease: lease,
    signal: getOrInitBrokerSignal(),
    active: true,
  )

proc ensureInit*[B](reg: var MtRegistry[B]) {.gcsafe.} =
  ## CAS(0→1) wins and initialises; losers spin until 2.
  if reg.state.load(moRelaxed) == 2:
    return
  var expected = 0
  if reg.state.compareExchange(expected, 1, moAcquire, moRelaxed):
    initLock(reg.lock)
    reg.cap = 4
    reg.buckets = cast[ptr UncheckedArray[B]](createShared(B, reg.cap))
    reg.count = 0
    reg.state.store(2, moRelease)
  else:
    while reg.state.load(moAcquire) != 2:
      discard

template locked*[B](reg: var MtRegistry[B], body: untyped) =
  {.cast(gcsafe).}:
    withLock(reg.lock):
      body

# The procs below must be called with `reg.lock` held.

proc append*[B](reg: var MtRegistry[B], bucket: B) {.gcsafe.} =
  if reg.count >= reg.cap:
    let newCap = reg.cap * 2
    let newBuf = cast[ptr UncheckedArray[B]](createShared(B, newCap))
    for i in 0 ..< reg.count:
      newBuf[i] = reg.buckets[i]
    # The old buffer is leaked on purpose: a reader that loaded the pointer
    # before this swap may still be iterating it.
    reg.buckets = newBuf
    reg.cap = newCap
  reg.buckets[reg.count] = bucket
  inc reg.count

proc removeAt*[B](reg: var MtRegistry[B], idx: int) {.gcsafe.} =
  for j in idx ..< reg.count - 1:
    reg.buckets[j] = reg.buckets[j + 1]
  dec reg.count

proc findIdx*[B](
    reg: MtRegistry[B], ctx: BrokerContext, requireActive = false
): int {.gcsafe.} =
  ## First bucket for `ctx` (any owner), or -1.
  for i in 0 ..< reg.count:
    if reg.buckets[i].head.ctx == ctx and
        (not requireActive or reg.buckets[i].head.active):
      return i
  -1

proc findOwnedIdx*[B](reg: MtRegistry[B], ctx: BrokerContext): int {.gcsafe.} =
  ## This thread's bucket for `ctx`, or -1.
  for i in 0 ..< reg.count:
    if reg.buckets[i].head.ctx == ctx and reg.buckets[i].head.isOwnedHere():
      return i
  -1

proc setupCheck*[B](
    reg: var MtRegistry[B], ctx: BrokerContext, policy: MtSetupPolicy
): MtSetupOutcome {.gcsafe.} =
  ## Decide, under the lock, whether a new bucket must be created for `ctx` on
  ## this thread. The three lanes differ on purpose (see `MtSetupPolicy`).
  case policy
  of mspOkIfOwned:
    let i = reg.findIdx(ctx)
    if i < 0:
      msoCreate
    elif reg.buckets[i].head.isOwnedHere():
      msoExisting
    else:
      msoRejected
  of mspRejectActive:
    if reg.findIdx(ctx, requireActive = true) >= 0: msoRejected else: msoCreate
  of mspReuseOwned:
    let i = reg.findOwnedIdx(ctx)
    if i < 0:
      msoCreate
    else:
      reg.buckets[i].head.hasListeners = true
      reg.buckets[i].head.active = true
      msoExisting

# Self-locking lookups.

proc hasBucket*[B](
    reg: var MtRegistry[B], ctx: BrokerContext, requireActive = false
): bool {.gcsafe.} =
  reg.locked:
    result = reg.findIdx(ctx, requireActive) >= 0

proc hasOwnedBucket*[B](reg: var MtRegistry[B], ctx: BrokerContext): bool {.gcsafe.} =
  reg.locked:
    result = reg.findOwnedIdx(ctx) >= 0

proc snapshot*[B](
    reg: var MtRegistry[B], ctx: BrokerContext, requireActive = false
): MtTarget[B] {.gcsafe.} =
  ## Find the bucket for `ctx`. A bucket owned by another thread is copied
  ## out with a lease reference taken under the lock; the caller must
  ## `release` it (or hand it on) after its last access to the transport.
  reg.locked:
    let i = reg.findIdx(ctx, requireActive)
    if i >= 0:
      result.found = true
      if reg.buckets[i].head.isOwnedHere():
        result.sameThread = true
      else:
        result.bucket = reg.buckets[i]
        acquireLease(result.bucket.head.lease)

proc release*[B](t: var MtTarget[B]) {.gcsafe.} =
  ## Drop the lease reference `snapshot` took (no-op otherwise; idempotent).
  if t.found and not t.sameThread:
    releaseLease(t.bucket.head.lease)
    t.found = false

proc ownedCtxs*[B](
    reg: var MtRegistry[B], requireActive = false
): seq[BrokerContext] {.gcsafe.} =
  ## Contexts of every bucket this thread owns (thread-exit cleanup).
  reg.locked:
    for i in 0 ..< reg.count:
      if reg.buckets[i].head.isOwnedHere() and
          (not requireActive or reg.buckets[i].head.active):
        result.add(reg.buckets[i].head.ctx)

proc removeOwnedLocked*[B](
    reg: var MtRegistry[B], ctx: BrokerContext, requireActive: bool, removed: var B
): BrokerReleaseOutcome {.gcsafe.} =
  ## Owner-only removal (call with `reg.lock` held). The bucket for `ctx` is
  ## removed only when this thread owns it, decided in the same critical
  ## section as the removal, so no other thread can retire + re-register in
  ## between: `broReleased` (copied to `removed`), `broAlreadyGone` (no
  ## bucket) or `broOwnerChanged` (owned by another thread, left in place).
  ## The caller then closes the ring and runs its lane-specific extras.
  let i = reg.findIdx(ctx, requireActive)
  if i < 0:
    return broAlreadyGone
  if not reg.buckets[i].head.isOwnedHere():
    return broOwnerChanged
  removed = reg.buckets[i]
  reg.removeAt(i)
  broReleased

proc removeOwned*[B](
    reg: var MtRegistry[B], ctx: BrokerContext, requireActive: bool, removed: var B
): BrokerReleaseOutcome {.gcsafe.} =
  ## Self-locking `removeOwnedLocked`.
  reg.locked:
    result = reg.removeOwnedLocked(ctx, requireActive, removed)
