## api_cbor_courier — runtime support for the CBOR FFI "buffer courier".
## =====================================================================
## Part C of the CBOR refactoring (doc/CBOR_Refactoring.md §6).
##
## A CBOR-mode `<lib>_call` runs on a foreign caller's thread. Instead of
## decoding CBOR and driving a momentary chronos loop on that foreign
## thread, it becomes a pure courier:
##
##   1. copy the API name into a fixed POD message,
##   2. hand the raw request buffer (by pointer, ownership transferred)
##      to the processing thread over a `Channel`,
##   3. block on a per-call response slot until the processing thread
##      writes the response back.
##
## The processing thread owns CBOR decode/encode and the provider call.
##
## This module is plain runtime code (NOT codegen) used by the generated
## library runtime in `api_library.nim`. It deliberately contains no Nim
## GC types on the cross-thread message path: `CborCallMsg` is pure POD,
## so a foreign thread can enqueue one with zero GC involvement.
##
## Memory model:
##   - `reqBuf`  — `allocShared0` by `<lib>_allocBuffer`; ownership moves
##     into the `CborCallMsg`; the processing thread frees it exactly once
##     after copying the bytes out.
##   - `respBuf` — `allocShared0` on the processing thread; ownership
##     returns to the `_call` thread via the slot; the foreign caller
##     frees it via `<lib>_freeBuffer`.
##   - Response slots use a `Lock`+`Cond` (zero OS handles) for the
##     blocking handoff — no busy-poll, no per-slot `ThreadSignalPtr`.

{.push raises: [].}

import std/[atomics, locks]

const CborApiNameMax* = 256
  ## Inline fixed-size buffer for the ASCII API name carried in a courier
  ## message. Carrying the name itself (rather than an interned id) keeps
  ## the message self-describing and avoids a separate id table that could
  ## silently desync from the dispatch `case`.

type
  CborCallMsg* = object
    ## Pure-POD message a foreign `_call` thread hands to the processing
    ## thread. No Nim `string`/`seq`/`ref` — safe to copy through a
    ## `Channel` with zero GC involvement on the foreign thread.
    apiName*: array[CborApiNameMax, char] ## NUL-terminated ASCII
    reqBuf*: pointer ## allocShared0; ownership transfers to the processing thread
    reqLen*: int32
    slotIdx*: int32 ## index of the response slot to complete
    targetCtx*: uint32
      ## reduced-A: the FULL BrokerContext the foreign caller addressed. For a
      ## main-context call this equals the library ctx; for a sub-instance call
      ## it carries the sub ctx (same classCtx as the library, distinct
      ## instanceCtx). The processing thread dispatches the adapter against this
      ## so the provider keyed by the sub ctx is reached.

  CborRespSlot = object
    lock: Lock
    cond: Cond
    inUse: Atomic[int] ## 0 free, 1 claimed — claimed via CAS
    ready: int ## guarded by `lock`: 0 pending, 1 complete
    respBuf: pointer ## allocShared0; ownership returns to the `_call` thread
    respLen: int32
    status: int32 ## the int32 `<lib>_call` returns to the foreign caller

  CborCallRing* = object
    ## Single-lock POD-element MPSC ring, allocated wholly in shared
    ## heap. Replaces `system.Channel[CborCallMsg]` deliberately: that
    ## channel allocates its message slots out of the sender thread's
    ## per-thread Nim allocator, and once the sender thread exits its
    ## TLS-tied allocator descriptor is freed by pthread cleanup. A
    ## subsequent `close()` on the shutdown thread walks straight into
    ## that dead descriptor (caught by ASAN on the stress_mt teardown
    ## path). This ring uses `allocShared` for its storage — single
    ## owner (the `CborCourier`), freed from the same thread that
    ## allocated it, no per-thread allocator involvement.
    buf: ptr UncheckedArray[CborCallMsg]
    cap: int
    head: int ## next index the consumer reads
    tail: int ## next index a producer writes
    count: int ## guarded by `lock`
    lock: Lock

  CborCourier* = object
    ## One per library context. Lives in shared heap; created in
    ## `_createContext`, freed in `_shutdown` after the processing thread
    ## has joined and all in-flight `_call`s have drained.
    ring*: CborCallRing
    slots: ptr UncheckedArray[CborRespSlot]
    slotCount: int
    inFlight*: Atomic[int]
      ## Count of `_call`s that passed the active-check but have not yet
      ## finished reading their slot. `_shutdown` waits for this to reach
      ## zero — while the processing thread is still handling — before it
      ## tells the processing thread to stop.

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

proc newCborCourier*(slotCount: int): ptr CborCourier =
  ## Allocate a courier with `slotCount` response slots. `slotCount` is the
  ## ceiling on concurrent in-flight `_call`s; the request ring is sized
  ## the same, so the slot pool gates the ring (a `_call` always claims a
  ## slot before enqueuing, so the ring cannot overflow).
  let c = cast[ptr CborCourier](allocShared0(sizeof(CborCourier)))
  c.ring.buf =
    cast[ptr UncheckedArray[CborCallMsg]](allocShared0(slotCount * sizeof(CborCallMsg)))
  c.ring.cap = slotCount
  c.ring.head = 0
  c.ring.tail = 0
  c.ring.count = 0
  initLock(c.ring.lock)
  c.slotCount = slotCount
  c.slots = cast[ptr UncheckedArray[CborRespSlot]](allocShared0(
    slotCount * sizeof(CborRespSlot)
  ))
  for i in 0 ..< slotCount:
    initLock(c.slots[i].lock)
    initCond(c.slots[i].cond)
    c.slots[i].inUse.store(0, moRelaxed)
  c

proc freeCborCourier*(c: ptr CborCourier) =
  ## Release a courier. MUST be called only after the processing thread
  ## has joined and `inFlight` has reached zero — see `_shutdown`.
  if c.isNil:
    return
  for i in 0 ..< c.slotCount:
    deinitCond(c.slots[i].cond)
    deinitLock(c.slots[i].lock)
  deallocShared(c.slots)
  deinitLock(c.ring.lock)
  if not c.ring.buf.isNil:
    deallocShared(c.ring.buf)
  deallocShared(c)

# ---------------------------------------------------------------------------
# Ring — MPSC over a fixed-size POD slot array. Single lock for both ends;
# the ring is not the contended path (per-call cost is dominated by the
# Cond handoff and the chronos coroutine spawn).
# ---------------------------------------------------------------------------

proc tryEnqueue*(r: ptr CborCallRing, msg: CborCallMsg): bool =
  ## Multi-producer. Returns false on full (no _call may be enqueued
  ## without first claiming a response slot, and the ring is sized to
  ## match `slotCount`, so a `false` here is a programming error).
  acquire(r.lock)
  if r.count >= r.cap:
    release(r.lock)
    return false
  r.buf[r.tail] = msg
  r.tail = (r.tail + 1) mod r.cap
  inc r.count
  release(r.lock)
  true

proc tryDequeue*(r: ptr CborCallRing, dst: var CborCallMsg): bool =
  ## Single consumer. Returns false on empty.
  acquire(r.lock)
  if r.count == 0:
    release(r.lock)
    return false
  dst = r.buf[r.head]
  r.head = (r.head + 1) mod r.cap
  dec r.count
  release(r.lock)
  true

# ---------------------------------------------------------------------------
# Response slots
# ---------------------------------------------------------------------------

proc claimSlot*(c: ptr CborCourier): int =
  ## Claim a free response slot. Returns its index, or -1 if the pool is
  ## exhausted (more concurrent `_call`s than `slotCount`).
  for i in 0 ..< c.slotCount:
    var expected = 0
    if c.slots[i].inUse.compareExchange(expected, 1, moAcquire, moRelaxed):
      let s = addr c.slots[i]
      acquire(s.lock)
      s.ready = 0
      s.respBuf = nil
      s.respLen = 0
      s.status = 0
      release(s.lock)
      return i
  -1

proc releaseSlot*(c: ptr CborCourier, idx: int) =
  ## Return a slot to the free pool. Call only after `waitSlot` returned.
  c.slots[idx].inUse.store(0, moRelease)

proc completeSlot*(
    c: ptr CborCourier, idx: int, respBuf: pointer, respLen: int32, status: int32
) =
  ## Processing-thread side: publish a response and wake the waiting
  ## `_call`. `respBuf` ownership passes to the `_call` thread.
  let s = addr c.slots[idx]
  acquire(s.lock)
  s.respBuf = respBuf
  s.respLen = respLen
  s.status = status
  s.ready = 1
  signal(s.cond)
  release(s.lock)

proc waitSlot*(
    c: ptr CborCourier, idx: int
): tuple[respBuf: pointer, respLen: int32, status: int32] =
  ## Foreign `_call` side: block until `completeSlot` publishes a response.
  ## Zero-fd blocking handoff via `Cond` — no busy-poll.
  let s = addr c.slots[idx]
  acquire(s.lock)
  while s.ready == 0:
    wait(s.cond, s.lock)
  result = (s.respBuf, s.respLen, s.status)
  s.ready = 0
  release(s.lock)

{.pop.}
