# Refactor: Replace `Channel[T]` in `(mt)` brokers with lock-free MPSC ring + slab

Living plan for the redesign that closes `doc/LIMITATION.md` §2.6 (macOS +
ORC `Channel[T]` slot-payload UAF after sender thread exit).

Branch: `refactor-channel-dispatch`.

---

## 0. Architectural invariants

These are load-bearing for §2.6 immunity. Every implementation phase must
respect them; CI tests should assert them where mechanically possible.

| ID | Invariant | Consequence |
|---|---|---|
| **I0** | Every `createShared` / `deallocShared` runs on the bucket-owning thread (and for the global event slab, on its designated owner thread). Sender threads never call any Nim allocator on the hot path. | Eliminates the §2.6 mechanism by construction. Phase 0 probe `test/probe_slab_workload.nim` is the structural witness. |
| **I1** | Senders only execute: atomic load/store/CAS, memcpy into pre-allocated cells, and `ThreadSignalPtr.fireSync()`. No allocator call. No Nim GC interaction beyond reading the type's `supportsCopyMem` predicate at compile time. | The hazard surface drops to zero on the hot path. |
| **I2** | The bucket-owning thread (and global-slab owner thread for events) must outlive every bucket / slab it owns. Documented in API surface; enforced by `doAssert currentMtThreadId() == owner.threadId` at allocation and free sites. | Ensures I0 can be honored. Without it, `shutdown(ctx)` cannot run on the owning thread → ring/slab leaks (the documented fallback when the user violates the contract). |

`test/probe_createshared_uaf.nim` (committed) is the cautionary counter-example
that disqualified the naive "wrap stdlib Channel" alternative.

---

## 1. Architecture overview

```
              GLOBAL (createShared, persistent for broker-type lifetime)
              ┌──────────────────────────────────────────────────────────┐
              │  EVENT broker only:                                      │
              │    eventGlobalSlab[T]                                    │
              │      cells: array[N, RefCountedCell]   // pre-allocated  │
              │      freeList: shardedFreeList         // ABA-tagged     │
              │    ownerThread: persistent (main / FFI processing thread)│
              └──────────────────────────────────────────────────────────┘

              SHARED (createShared, per-bucket lifetime)
              ┌──────────────────────────────────────────────────────────┐
              │  Bucket[ctx, threadId, threadGen] {                      │
              │    ring: ptr VyukovMpscRing[Slot]                        │
              │    requestSlab: ptr PayloadSlab  ◄─ RequestBroker only   │
              │    responseSlotPool: ptr ResponseSlotPool ◄─ Req only    │
              │    closed: Atomic[bool]                                  │
              │    hasProvider / hasListeners: bool                      │
              │    signal: ThreadSignalPtr (per-thread, shared)          │
              │  }                                                       │
              │  ownerThread: bucket.threadId (where listen/setProvider  │
              │                                ran)                      │
              └──────────────────────────────────────────────────────────┘
                              │                          │
                  cross-thread│                          │same-thread
                              ▼                          ▼
   ┌──────────────────────────────────┐    ┌──────────────────────────────┐
   │  sender thread                    │    │  bucket-owning thread        │
   │  ──────────────                   │    │  ─────────────────           │
   │  EVENT:                           │    │  emit/request on this        │
   │    1. claim global-slab cell      │    │  thread bypasses ring;       │
   │       (atomic free-list pop)      │    │  direct asyncSpawn / await   │
   │    2. marshal payload into cell   │    │  via tvHandlers.             │
   │    3. set cell.refcount = N       │    │                              │
   │    4. for each target bucket:     │    │  poll fn (consumer):         │
   │       atomic enqueue cell ptr     │    │    pop slot from ring        │
   │       into bucket.ring            │    │    EVENT: dispatch handlers, │
   │       fire bucket.signal          │    │      decRef(cell), free if 0 │
   │                                   │    │    REQUEST: invoke provider, │
   │  REQUEST:                         │    │      write to ResponseSlot,  │
   │    1. claim ResponseSlot from     │    │      decRef(slot)            │
   │       bucket.responseSlotPool     │    │                              │
   │    2. claim request-slab cell     │    │  shutdown(ctx):              │
   │       (atomic free-list pop)      │    │    ring.closed.store(true)   │
   │    3. marshal payload + return    │    │    drain ring                │
   │       ResponseSlot ptr into cell  │    │    decRef in-flight cells    │
   │    4. atomic enqueue cell ptr     │    │    deallocShared ring +      │
   │       into bucket.ring            │    │      requestSlab +           │
   │       fire bucket.signal          │    │      responseSlotPool        │
   │    5. await ResponseSlot signal   │    │    remove bucket entry       │
   │    6. read result; decRef slot    │    │                              │
   │                                   │    │                              │
   │  no Nim allocator calls on        │    │                              │
   │  steps 1-6 except marshaling      │    │                              │
   │  into PRE-ALLOCATED cells.        │    │                              │
   └──────────────────────────────────┘    └──────────────────────────────┘
```

Tier A vs Tier B is decided at broker-declaration macro time per type `T`:

- **Tier A** = `supportsCopyMem(T)` is true → payload inlined in slot. No
  slab needed (events still use a global cell-of-T pool for refcount
  sharing; requests inline directly in the ring slot).
- **Tier B** = `T` contains `string` / `seq[primitive]` / nested object →
  macro emits per-type `marshal`/`unmarshal` procs; slot carries a pointer
  to a pre-allocated fixed-size byte cell; `maxPayloadBytes` parameter
  caps cell size; oversize causes compile-time-detected `err` at runtime.
- **Forbidden at macro time:** `ref T`, `ptr T`, `cstring`, `pointer`,
  function-typed fields — any non-self-contained value type.

---

## 2. File layout

**New:**

| File | Contents |
|---|---|
| `brokers/internal/mt_queue.nim` | Plain Nim primitives, no macro: `VyukovMpscRing`, `PayloadSlab`, `RefCountedCell`, `ResponseSlot`, `ResponseSlotPool`, sharded-free-list helpers, atomic-ordering helpers. All `gcsafe`, `raises: []`. `createShared`/`deallocShared` only — no `new`, no `ref`. |
| `brokers/internal/mt_codec.nim` | Compile-time only: `isInlinable(T) -> bool`, `genMarshal(T, bufSize) -> NimNode`, `genUnmarshal(T, bufSize) -> NimNode`, `forbidUnsafePayloads(T)`. Operates on `getTypeImpl` nodes. |

**Modified:**

| File | Change |
|---|---|
| `brokers/internal/mt_broker_common.nim` | Add: `closed` flag helpers, drain coordinator (used by both event and request shutdown paths). No structural change to existing dispatch-loop infrastructure. |
| `brokers/internal/mt_event_broker.nim` | Replace `eventChan: ptr Channel[T]` with `ring: ptr VyukovMpscRing[Slot]`. Add global slab access. Rewrite `emit` cross-thread branch. Rewrite poll fn to dequeue + decRef. Same-thread branch unchanged. |
| `brokers/internal/mt_request_broker.nim` | Replace `requestChan` with ring + per-bucket request slab. Replace per-call `responseChan: createShared(Channel[T])` with claim from bucket's `responseSlotPool`. |
| `brokers/internal/helper/broker_utils.nim` | Parse new declaration pragmas: `maxQueueDepth: N`, `maxPayloadBytes: B`, `slabCapacity: M`, `responseSlotPool: K`. |

**Untouched:** `broker_context.nim`, `event_broker.nim` (single-thread re-exports), `request_broker.nim`, `multi_request_broker.nim`, `api_*` files (CBOR codegen — automatic beneficiary).

---

## 3. Data structures

### 3.1 `VyukovMpscRing[Slot]` (mt_queue.nim)

Bounded MPSC, capacity power-of-2, cache-line padded.

```nim
type
  RingHeader = object
    mask: uint64                # capacity - 1
    capacity: uint64
    closed: Atomic[bool]        # set by shutdown; checked by producers
    enqPos: Atomic[uint64]
    pad0: array[64 - 8 - 1 - 8 - 8, byte]  # cache-line separation
    deqPos: uint64              # consumer-only; not atomic
    pad1: array[64 - 8, byte]

  Slot[T] = object
    seq: Atomic[uint64]         # Vyukov visibility gate
    payload: T                  # Tier A: inline T; Tier B: ptr RefCountedCell

  VyukovMpscRing[T] = object
    header: RingHeader
    slots: UncheckedArray[Slot[T]]
```

**Allocation:** `createShared` one contiguous block of
`sizeof(RingHeader) + cap * sizeof(Slot[T])`. Always done on the
bucket-owning thread.

**Atomic protocol (single-consumer specialization of Vyukov bounded MPMC):**

Producer (`tryEnqueue`):
1. `if header.closed.load(moAcquire): return false`
2. `pos = header.enqPos.load(moRelaxed)`
3. Loop:
   - `slot = addr slots[pos and mask]`
   - `seq = slot.seq.load(moAcquire)`
   - `diff = seq - pos`
   - `if diff == 0`: try CAS `enqPos: pos → pos+1` (release). If success, break. Else reload pos.
   - `elif diff < 0`: queue full → return false (no FAA, no hole left)
   - `else`: another producer claimed this slot; reload pos.
4. Re-check `header.closed.load(moAcquire)`; if true: forfeit slot by storing `slot.seq = pos+1` (so consumer sees an "empty" slot that drain logic ignores), return false.
5. Write payload into `slot.payload`.
6. `slot.seq.store(pos + 1, moRelease)` — publish.

Consumer (`tryDequeue`, single-threaded):
1. `pos = deqPos`
2. `slot = addr slots[pos and mask]`
3. `seq = slot.seq.load(moAcquire)`
4. `if seq != pos + 1`: return false (empty)
5. Read payload from `slot.payload`.
6. `slot.seq.store(pos + capacity, moRelease)` — slot reusable.
7. `deqPos = pos + 1`
8. Return true.

**Forfeited slots from step 4:** a slot whose `seq = pos+1` but with no
payload write. The consumer must distinguish — solution: producer writes
a sentinel (e.g., `payload.isForfeit = true` for ptr-typed payloads, or
a separate `forfeit` atomic flag in the slot). Simpler: do the close
check *before* CAS at step 3 instead of after step 3 → no forfeit needed.
Risk: producer that observed `closed=false` then CAS-claims slot must
publish; shutdown drain waits for `enqPos` to stabilize past its closing
snapshot. **Pick this simpler path.** Drain logic:
```
header.closed.store(true, moRelease)
stable = false
prev = header.enqPos.load(moAcquire)
while not stable:
  spinSleep(50µs)
  cur = header.enqPos.load(moAcquire)
  stable = (cur == prev)
  prev = cur
# now all in-flight publishes complete; drain to prev
```

### 3.2 `PayloadSlab` (mt_queue.nim) — RequestBroker only

```nim
type
  PayloadSlab = object
    cellSize: uint32            # aligned to cache line
    capacity: uint32
    storage: ptr UncheckedArray[byte]   # createShared(capacity * cellSize)
    freeList: ShardedFreeList   # see 3.5

  RequestCell = object           # the typed view of one slab cell
    refcount: Atomic[int]        # init 1 (provider releases when done)
    responseSlotIdx: uint32      # index into bucket.responseSlotPool
    payloadSize: uint16          # marshaled byte length (Tier B)
    payloadCap: uint16           # = cellSize - header (Tier B)
    payloadBytes: UncheckedArray[byte]  # Tier B: marshaled; Tier A: T inlined
```

`createShared` once at bucket creation. `deallocShared` at `shutdown(ctx)`.

### 3.3 `RefCountedCell` (mt_queue.nim) — EventBroker only, in the global event slab

```nim
type
  RefCountedCell = object
    refcount: Atomic[int]        # init = number of target buckets
    payloadSize: uint16
    payloadCap: uint16
    payloadBytes: UncheckedArray[byte]
```

Lives in the global per-broker-type slab. Same field layout as
`RequestCell` minus `responseSlotIdx`. Could unify if convenient.

### 3.4 `ResponseSlotPool` (mt_queue.nim) — RequestBroker only

Per-bucket pre-allocated pool of single-shot response slots, claimed by
requesters from any thread via atomic free-list, released after read.
Replaces today's per-call `createShared(Channel[Result[T,string]])`.

```nim
type
  ResponseState {.pure.} = enum
    Empty = 0       # claimed by requester, not yet filled
    Ready = 1       # provider wrote payload; requester not yet read
    Abandoned = 2   # requester gave up (timeout); provider must not write

  ResponseSlot[T] = object
    state: Atomic[uint8]
    signal: ThreadSignalPtr     # requester's per-thread shared signal
    payload: T                  # Result[T, string] inlined
    poolIdx: uint32             # index for free-list return

  ResponseSlotPool[T] = object
    capacity: uint32
    storage: ptr UncheckedArray[ResponseSlot[T]]
    freeList: ShardedFreeList
```

**State machine:**
- Requester: claim slot from pool (atomic free-list pop), set
  `state=Empty, signal=mySignal`, push request cell carrying
  `responseSlotIdx`, await signal.
- Provider: read `responseSlotIdx` from request cell, locate slot. CAS
  `state: Empty → Ready` while writing payload. If CAS fails (state was
  `Abandoned`): skip write, but still return slot to free-list. If CAS
  succeeds: write payload, then `state.store(Ready, moRelease)`, fire
  requester's signal.
- Requester wakes: load `state`, read payload, return slot to free-list.
- Requester timeout: CAS `state: Empty → Abandoned`. The provider sees
  Abandoned, skips write, returns slot. (If CAS fails because state was
  already Ready, requester reads the payload and returns slot normally.)

Sizing: `responseSlotPool: K` declaration pragma; default = `maxQueueDepth`.
Pool exhaustion = back-pressure (same back-off as ring-full; see §6).

### 3.5 `ShardedFreeList` (mt_queue.nim)

Reduces contention on slab + pool free-lists across many sender threads.

```nim
type
  FreeListShard = object
    head: Atomic[uint64]   # idx (low 32) + tag (high 32) for ABA
    pad: array[64 - 8, byte]

  ShardedFreeList = object
    nShards: uint32        # power-of-2; e.g. 4 or 8
    shards: ptr UncheckedArray[FreeListShard]
    nextLinks: ptr UncheckedArray[uint32]  # parallel array: idx → next idx
```

- `pop(threadHash)`: pick shard `threadHash and (nShards-1)`. Treiber pop with
  tagged head to dodge ABA. If empty, linear scan other shards.
- `push(idx, threadHash)`: pick shard `threadHash and (nShards-1)`. Treiber push.

`threadHash` = `cast[uint32](currentMtThreadId()) shr 4` — cheap, stable per thread.

`nShards` default = 4; broker pragma `freeListShards: N` (power-of-2).

### 3.6 Bucket struct updates

Event broker bucket:
```nim
bucketName = object
  brokerCtx: BrokerContext
  ring: ptr VyukovMpscRing[EventSlot]    # was: eventChan: ptr Channel[T]
  listenerSignal: ThreadSignalPtr
  threadId: pointer
  threadGen: uint64
  active: bool
  hasListeners: bool
```

Request broker bucket:
```nim
bucketName = object
  brokerCtx: BrokerContext
  ring: ptr VyukovMpscRing[RequestSlot]   # was: requestChan: ptr Channel[T]
  requestSlab: ptr PayloadSlab            # Tier B only; nil for Tier A
  responseSlotPool: ptr ResponseSlotPool  # NEW
  providerSignal: ThreadSignalPtr
  threadId: pointer
  threadGen: uint64
  active: bool
  hasProvider: bool
```

Slot types (per-broker, generated by macro):
- Tier A: `EventSlot = ptr RefCountedCell` (still ptr — cell carries the inlined T plus refcount).
- Tier A request: `RequestSlot = RequestCell` (inlined cell directly in slot since no fan-out).
- Tier B: same pattern; cells carry marshaled bytes instead of `T`.

Actually, for Tier A events we still want refcount sharing across fan-out, so cell-by-ptr in slot is the right shape regardless of tier. Detailed slot layout finalized in Phase 2.

---

## 4. Same-thread fast path

**Unchanged behavior. Decision point: same as today.**

In `emit` / `request` cross-thread implementations, the dispatch logic walks
the bucket registry. For each matching bucket:

```nim
if bucket.threadId == myThreadId and bucket.threadGen == myThreadGen:
  # SAME-THREAD FAST PATH — bypass ring/slab/pool entirely
  if isEvent:
    for cb in tvListenerHandlers[ctxIdx].values:
      asyncSpawn listenerTaskIdent(cb, event)
  else:  # request
    let provider = tvProviderHandler[ctxIdx]
    return await provider(...)
else:
  # CROSS-THREAD: ring + slab + (response slot pool) path
  ...
```

**Trivially §2.6-immune**: no `Channel.send`, no `allocShared`, no slot ring
to corrupt. Same-thread sender is by definition not transient relative to
itself.

---

## 5. Macro codegen: Tier A vs Tier B

### 5.1 Decision (compile time)

Predicate `isInlinable(T: NimNode): bool` walks `getTypeImpl(T)`:

| T contains | Inlinable? | Path |
|---|---|---|
| Scalar (int/uint/float/bool/enum/char) | yes | inline |
| `array[N, U]` where U is inlinable | yes | inline |
| `object` whose fields are all inlinable | yes | inline |
| `string` | no | marshal |
| `seq[U]` (U is inlinable) | no | marshal |
| `seq[U]` (U non-inlinable) | yes (recursive marshal) | marshal |
| Tuple of inlinable | yes | inline |
| Nested object: object with object fields recursively inlinable | yes | inline |
| `ref T`, `ptr T`, `cstring`, `pointer`, proc-typed | — | **macro-time error** |

### 5.2 Tier A — POD inline

```
emit code (cross-thread branch, per target bucket):
  cell := global_event_slab.claim(threadHash)
  if cell == nil:
    # slab exhausted (back-pressure for events: log + drop)
    chronicles.warn "event dropped: slab exhausted"
    return
  copyMem(addr cell.payloadBytes[0], unsafeAddr T_value, sizeof(T))
  cell.payloadSize = uint16(sizeof(T))
  cell.refcount.store(N_targets, moRelaxed)
  for each target bucket:
    if not bucket.ring.tryEnqueue(cell):
      chronicles.warn "event dropped: queue full"
      atomicDec(cell.refcount)  # this listener won't see it
    else:
      fireBrokerSignal(bucket.signal)
  if cell.refcount.load(moAcquire) == 0:
    # all targets dropped → release cell
    global_event_slab.release(cell)

consumer code (poll fn on listener thread):
  while ring.tryDequeue(cellPtr):
    # decode (Tier A: direct memcpy)
    var ev: T
    copyMem(addr ev, addr cellPtr.payloadBytes[0], sizeof(T))
    for cb in tvListenerHandlers[ctxIdx].values:
      asyncSpawn listenerTaskIdent(cb, ev)
    # the cell can be decRef'd as soon as we extracted the value
    # (handlers operate on the local copy)
    if atomicSub(cellPtr.refcount, 1) == 0:
      global_event_slab.release(cellPtr)
```

Per-emit cost: 1 slab claim + 1 memcpy + N atomic ring pushes + N signal fires.

### 5.3 Tier B — marshaled bytes

Macro emits, per broker type:

```nim
proc `marshal_T`(buf: ptr UncheckedArray[byte], cap: int, v: T): int
  # writes v's bytes into buf, returns bytes written or -1 on overflow
  # format: scalars by memcpy, strings/seqs length-prefixed (uint32 LE)

proc `unmarshal_T`(buf: ptr UncheckedArray[byte], len: int, v: var T): bool
  # reads bytes into v (allocates string/seq on caller's GC heap)
  # returns false on truncated/malformed input
```

Emit branch:
```
cell := global_event_slab.claim(threadHash)
written := marshal_T(addr cell.payloadBytes[0], cell.payloadCap, ev)
if written < 0:
  chronicles.error "event payload exceeds maxPayloadBytes", typ = $T
  global_event_slab.release(cell)
  return
cell.payloadSize = uint16(written)
cell.refcount.store(N_targets, moRelaxed)
# ... same fan-out push loop as Tier A
```

Consumer:
```
var ev: T
if not unmarshal_T(addr cellPtr.payloadBytes[0], int(cellPtr.payloadSize), ev):
  chronicles.error "event payload malformed"
else:
  for cb in handlers: asyncSpawn ...
if atomicSub(cellPtr.refcount, 1) == 0:
  global_event_slab.release(cellPtr)
```

**Important:** `unmarshal_T` allocates string/seq on the **consumer thread's**
GC heap. Strings flow to handlers as normal Nim values. This is the §2.6
fix: no string/seq pointer ever crosses a thread boundary except as bytes
inside an immutable slab cell.

`maxPayloadBytes` defaults to 4096; user can override per broker:
```nim
EventBroker(mt, maxPayloadBytes = 16384):
  type LargeEvt = object
    blob: seq[byte]
```

### 5.4 Marshaling format

Stable, self-describing-enough for round-trip, NOT cross-language:

```
scalar:        copyMem(N bytes), N = sizeof(scalar)
enum:          int32
fixed array:   N concatenated element encodings
string:        uint32 len + len bytes (utf8 bytes verbatim)
seq[T]:        uint32 len + len element encodings
object:        each field in declaration order
```

No type tags, no schema — the type is known at codegen time and identical
on both sides. The marshaler/unmarshaler are generated as a matched pair
from the same `T` and are fully closed under self-replacement.

---

## 6. Back-pressure

### 6.1 Pragmas (parsed by broker_utils.nim)

```nim
EventBroker(mt,
            maxQueueDepth = 1024,        # ring capacity per bucket
            maxPayloadBytes = 4096,      # Tier B cell size
            slabCapacity = 8192,         # global event slab cells
            freeListShards = 4):
  type ...

RequestBroker(mt,
              maxQueueDepth = 256,
              maxPayloadBytes = 4096,
              slabCapacity = 256,
              responseSlotPool = 256,
              freeListShards = 2):
  type ...
```

Defaults sensible for typical FFI API workloads; override per broker.

### 6.2 Events: best-effort with logged drops

- Slab cell claim fails (slab exhausted): `chronicles.warn "event dropped: slab exhausted"`. No retry; emit returns.
- Ring `tryEnqueue` fails for one or more target buckets (queue full): `chronicles.warn "event dropped: listener queue full"`, decRef the cell for that target, continue with remaining targets. Partial fan-out is acceptable.
- Marshaler overflow (Tier B): `chronicles.error "event payload exceeds maxPayloadBytes"`. Drop. (User should size the broker correctly; this is a configuration bug.)

### 6.3 Requests: bounded async back-off with eventual `err`

```nim
const fullRetryAttempts = bucket.ring.capacity  # bound
var attempt = 0
while not bucket.ring.tryEnqueue(cellPtr):
  inc attempt
  if attempt > fullRetryAttempts:
    bucket.requestSlab.release(cellPtr)
    bucket.responseSlotPool.release(responseSlotIdx)
    return err("RequestBroker(" & typeName & "): provider queue full")
  await sleepAsync(milliseconds(1 shl min(attempt, 6)))  # cap at 64ms
fireBrokerSignal(bucket.signal)
# now await on responseSlot.signal as before
```

Same for ResponseSlotPool exhaustion. `blockingRequest` uses `sleep` (sync)
in place of `sleepAsync`.

### 6.4 Why not block indefinitely on the request side

A stuck provider would deadlock the caller's chronos event loop until
external timeout. Bounded retry with `err` lets the caller's existing
`withTimeout` path (already present in `request()`) handle the failure
cleanly and lets the caller cancel.

---

## 7. Bucket lifecycle

### 7.1 Decision: explicit `shutdown` for resource reclamation

`clearProvider` / `dropAllListeners` **do not** free ring + slab. Only the
explicit `shutdown(ctx)` path does. (See "Open questions" in conversation
— this was your call.)

| API | Effect |
|---|---|
| `setProvider(ctx)` / `listen(ctx, h)` | If bucket missing for (ctx, this_thread, this_gen) on registry → `createShared` ring + request-slab + response-slot-pool on this thread. Add to registry. Else → register handler in tvTable, set `hasProvider`/`hasListeners=true`. |
| `clearProvider(ctx)` / `dropListener(h)` / `dropAllListeners(ctx)` | Remove handler from `tvHandlers`. If none remain on this (ctx, thread): set `hasProvider`/`hasListeners=false`. Poll fn drains: pending requests get `err("no provider")` via response slots; pending events get `decRef`'d. Ring + slab + pool stay. |
| `shutdown(ctx)` (NEW public API) | Must run on bucket-owning thread. Steps: (a) `ring.closed.store(true, moRelease)`; (b) drain via poll fn until `ring.enqPos` stabilizes and ring empty; (c) walk `requestSlab` / event-global-slab inUse bitmap, force-`decRef` any remaining in-flight cells to 0 with appropriate err / drop; (d) `deallocShared` ring + requestSlab + responseSlotPool; (e) remove bucket from registry; (f) clear corresponding tvHandlers entries. |

### 7.2 Global event slab lifecycle

- Allocated lazily on first `listen()` or first `emit()`, on whichever
  thread first triggers. That thread becomes "owner".
- Alternative: explicit `EvtType.preInit()` callable from main, recommended
  for predictability.
- Owner thread must outlive the slab (I2).
- Freed via explicit `EvtType.shutdownGlobalSlab()` (only on owner thread)
  or — acceptable default — never (process-lifetime).
- Same `closed` flag pattern for orderly shutdown: producers check before
  cell claim.

### 7.3 Drain coordinator

In `mt_broker_common.nim`, helper used by both event and request shutdown:

```nim
proc drainRing*[T](ring: ptr VyukovMpscRing[T];
                   pollFn: ThreadDispatchPollFn;
                   spinSleepUs: int = 50) =
  ring.header.closed.store(true, moRelease)
  var prev = ring.header.enqPos.load(moAcquire)
  var stable = false
  while not stable:
    while pollFn() == 1: discard  # poll fn returns 1 if it processed an item
    discard usleep(spinSleepUs)
    let cur = ring.header.enqPos.load(moAcquire)
    stable = (cur == prev) and ring.header.enqPos.load(moAcquire) == ring.deqPos
    prev = cur
```

Replaces today's 50ms grace-sleep + `Channel.close` pattern with a
deterministic synchronization point.

---

## 8. Lifecycle flows (recap; full discussion in conversation)

**Flow A (RequestBroker, clear+set on T1):** same bucket, ring, slab, pool reused; zero allocator traffic during the cycle. §2.6-safe trivially.

**Flow B (RequestBroker, clear on T1, set on T2):** two separate buckets; bucket_A on T1 with `hasProvider=false` becomes a ghost until T1 calls `shutdown(ctx)`. Bucket_B on T2 lives independently. Sender lookup ignores `hasProvider=false` buckets. All allocator calls remain on the owning thread (T1 owns bucket_A's resources, T2 owns bucket_B's). If T1 exits without `shutdown`: bucket_A leaks (bounded by process lifetime). No UAF.

**Flow C (EventBroker, dropAllListeners + relisten same thread, same ctx):** bucket reused, ring + global-slab unchanged. Poll fn drains pending cells during the no-listener window (decRef → returned to global slab). Relisten attaches `h2` and emission resumes. §2.6-safe.

**Flow C variant (drop on T1, listen on T2):** two buckets, same ghost pattern as Flow B; documented.

---

## 9. Migration phasing

Each phase merges independently with its own tests passing.

| Phase | Scope | Gate |
|---|---|---|
| **0. Probes** ✓ | `probe_createshared_uaf.nim` (counter-example, fails as expected), `probe_slab_workload.nim` (target pattern, passes). | Done — committed on this branch. |
| **1. mt_queue primitives** | `brokers/internal/mt_queue.nim` with `VyukovMpscRing`, `PayloadSlab`, `RefCountedCell`, `ResponseSlot`, `ResponseSlotPool`, `ShardedFreeList`. Unit tests + MPSC stress test under ASAN+TSAN, orc+refc, on macOS+Linux. | Stress tests green on macOS+ORC+ASAN. |
| **2. EventBroker Tier A** | Replace channel in `mt_event_broker.nim` for POD payloads only. Macro errors out for non-POD with "Tier B pending in Phase 3". Re-enable `concurrent emitters from multiple threads` test on macOS+ORC. | Failing-on-master test now passes on macOS+ORC+ASAN. |
| **3. EventBroker Tier B (marshal/unmarshal codegen)** | Add `mt_codec.nim`. Non-POD event payloads work. Re-enable `seq_object_event_rapid_fire_no_leak` and `seq_object_event_concurrent_listeners_and_requesters`. | Full event-broker test set green on all platforms. |
| **4. RequestBroker (Tier A + B + ResponseSlotPool)** | Replace request channel + per-call response channel. Re-enable `concurrent requests from multiple threads` and `test_foreign_thread_concurrent_*` (C++ side). | All ASAN tasks green on macOS+ORC; same on Linux+refc. |
| **5. Cleanup** | Remove all `import .../channels_builtin` from broker code; verify `grep -r Channel[ brokers/` returns only re-exports or comments. Update `doc/LIMITATION.md` §2.6 to "fixed in vX.Y". Remove `brokerTestsSkipFragileRefcBursts` gates that were §2.6-specific. Update `doc/MultiThread_RequestBroker.md` and `doc/MultiThread_EventBroker.md` (if exists) Memory Layout sections. | docs current; CI green on all matrix cells; macOS+ORC support matrix entry flips from ⚠️ back to ✅. |

---

## 10. Risks and unknowns

| ID | Risk | Mitigation |
|---|---|---|
| R1 | Vyukov correctness under our chosen atomic orderings, specialized to single-consumer. | Phase 1: paper proof + TSAN coverage + adversarial MPSC stress test. |
| R2 | Macro complexity ceiling for Tier B (nested objects, `seq[Obj]`, `seq[seq[T]]`). | Phase 3: keep marshaler recursive but limit recursion depth at macro time; reject anything that can't be statically resolved. |
| R3 | Performance regression vs `Channel[T]`. | Phase 1: microbench against today's `Channel[T]` in `perf_test_multi_thread_event_broker.nim` and `perf_test_multi_thread_request_broker.nim`. Cache-line padding + pre-allocated slab should make uncontended throughput similar; expected win under contention. |
| R4 | Slab / pool exhaustion under sustained fan-out or burst load. | Pragma exposure of `slabCapacity` / `responseSlotPool`. Documented in broker decl. `chronicles.warn`/`err` on exhaustion makes it visible. |
| R5 | Global event slab contention on the free-list under N-way concurrent emits. | Sharded free-list (4-8 shards) hashed by thread id. Microbench in Phase 3. |
| R6 | ABA on `ShardedFreeList` Treiber stacks under high churn. | 32-bit tag in head word (64-bit CAS); tag bumps on every push. |
| R7 | Macro-emitted marshaler ABI stability between Nim versions. | The marshaler is bit-for-bit deterministic per type; macro-generated; no cross-version concern within a single build. We never serialize-to-disk; in-process only. |
| R8 | `chronicles.warn` from a sender thread under refc — does it allocate on the sender's GC heap? | Yes, and that's fine for `chronicles` because the allocation is consumed by the logger before any thread exit can strand it. But verify: under §2.6's strict reading, even one allocation on a sender thread is a hazard if any reference to that allocation persists across thread exit. `chronicles.warn` typically doesn't retain refs. Phase 2: ASAN-test with concurrent emitters + warn-on-drop. |
| R9 | Lifetime of `ThreadSignalPtr` referenced by `ResponseSlot.signal`. | Today's `requesterSignal` is the per-thread shared signal from `mt_broker_common`; pointer remains valid past `joinThread` because it's stored in `gBrokerThreadSignal` (threadvar but persists in shared structures via `registerBrokerPoller`). Unchanged in this design. |

---

## 11. Test strategy

### 11.1 New unit tests (Phase 1)

- `test/test_mt_queue_ring.nim`
  - Single-producer, single-consumer FIFO correctness.
  - MPSC stress: 16 producers × 100k ops, verify count + ordering-per-producer.
  - Closed-flag handoff: producer that observes `closed=true` returns false; producer that observed `closed=false` always completes (drain waits).
- `test/test_mt_queue_slab.nim`
  - Concurrent pop/push (ShardedFreeList) under 16 threads.
  - ABA detector (tag bump verification).
  - Drain-on-shutdown empties the in-use bitmap.
- `test/test_mt_queue_refcount.nim`
  - 16 threads `decRef` the same cell; exactly one observer sees 0.
  - Cell returned to slab on zero-refcount.
- `test/test_mt_queue_respond_slot.nim`
  - Provider-completes-first vs requester-times-out-first state-machine races.
  - Slot returned to pool after both decRefs.

### 11.2 Codec tests (Phase 3)

- `test/test_mt_codec.nim`
  - Round-trip every supported `T` shape: scalars, arrays, strings, `seq[primitive]`, `seq[Object]`, nested objects.
  - Compile-time rejection: `ref T`, `ptr T`, `cstring`, proc-typed.
  - Truncation handling: oversize payload → marshaler returns -1; consumer logs and drops.

### 11.3 Integration tests (Phases 2-4)

- `test/test_mt_backpressure_event.nim`
  - Fill ring → emit → assert `chronicles.warn` line captured + consumer still receives older events.
- `test/test_mt_backpressure_request.nim`
  - Fill ring → request returns `err("queue full")` after expected back-off window.
- `test/test_mt_response_slot_timeout.nim`
  - Provider slow → requester times out → slot returned cleanly.
- `test/test_mt_lifecycle.nim`
  - Flow A, Flow B, Flow C scenarios reified as named tests, all under ASAN+ORC+macOS as well as refc+Linux.

### 11.4 Re-enabled existing tests (Phases 2, 4)

- `test/test_multi_thread_event_broker.nim` → `"concurrent emitters from multiple threads"` (remove `when not defined(brokerTestsSkipFragileRefcBursts)` gate after Phase 2).
- `test/test_multi_thread_request_broker.nim` → `"concurrent requests from multiple threads"` (after Phase 4).
- `test/typemappingtestlib/test_typemappingtestlib.cpp`: re-enable `test_foreign_thread_concurrent_lifecycle`, `test_seq_object_event_rapid_fire_no_leak`, `test_foreign_thread_concurrent_seq_*` family (after Phase 4).

### 11.5 Regression suite update

- Keep `test/probe_mt_uaf.nim` as a regression test against the original §2.6 reproducer; after Phase 4, **all six probe modes including `relisten`, `gcCollect`, `shutdownEach` must exit 0** under macOS+ORC+ASAN.
- Keep `test/probe_slab_workload.nim` as the structural invariant test.
- `test/probe_createshared_uaf.nim` stays as a documented "do not allocate cross-thread" cautionary artifact (excluded from CI runs because it is expected to fail by design; covered by a comment header).

### 11.6 Memcheck CI matrix updates

After Phase 4:

| Job | Before | After |
|---|---|---|
| `testMtEventBrokerAsanOrc` (macOS) | failing (gated tests skipped, real bug behind nimble 0.22 mask) | green, full coverage |
| `testMtRequestBrokerAsanOrc` (macOS) | failing similarly | green, full coverage |
| `testFfiApiCppAsanOrc` (macOS) | partial (some scenarios gated) | green, full coverage |
| All Linux+refc and Linux+ORC matrix cells | green | green (no change expected) |
| macOS+refc matrix cells | green except 2.2.4-debug carve-out | unchanged |

---

## Appendix A: API additions

- `proc shutdown*(_: typedesc[T]): Future[void] {.async.}` — new public proc on every `(mt)` broker. Must run on the bucket-owning thread for the default context.
- `proc shutdown*(_: typedesc[T], ctx: BrokerContext): Future[void] {.async.}` — same for explicit context.
- `proc shutdownGlobalSlab*(_: typedesc[T]) {.gcsafe.}` (events only) — optional, for callers who want to free the global slab on clean exit. Must run on the slab's owner thread.

Existing APIs (`emit`, `request`, `listen`, `setProvider`, `dropListener`,
`dropAllListeners`, `clearProvider`) keep their signatures and semantics.

## Appendix B: Pragma additions on broker declarations

```nim
EventBroker(mt,
            maxQueueDepth = N,      # ring capacity, must be power-of-2 (default 1024)
            maxPayloadBytes = B,    # Tier B cell size (default 4096; ignored for Tier A)
            slabCapacity = M,       # global slab capacity (default 8192)
            freeListShards = S):    # default 4
  type T = object ...
```

Same shape for `RequestBroker(mt, ...)` with the additional `responseSlotPool = K`.
