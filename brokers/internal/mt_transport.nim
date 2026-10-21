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

import std/atomics
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
