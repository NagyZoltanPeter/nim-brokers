# Flexible MT Dispatch — Implementation Plan

**Branch:** `flexible-mt-dispatch`
**Scope:** the multi-thread (MT) internal lane only — `EventBroker(mt)` /
`RequestBroker(mt)` and the slab/response-pool machinery in
`brokers/internal/mt_queue.nim`. The FFI / CBOR courier lane
(`api_*_cbor*`, `api_library.nim`) is **out of scope** — it already passes
`pointer + len` per message and has no fixed-cell size bound.

## Motivation

Today the MT lane copies a marshaled payload into a **fixed slab cell** of
`cellPayloadCap == maxPayloadBytes` bytes. Two limits compound:

1. **Type ceiling.** `CellHeader.payloadSize` and the response-slot size field
   are `uint16` (`mt_queue.nim:271`, `:374-377`). Any configured cell larger
   than 65 535 B silently wraps — e.g. a full 64 KiB (`largePayload` preset,
   `maxPayloadBytes = 65536`) writes `payloadSize = 0`. Our real messages can
   exceed **1 MiB**, so the type itself is wrong.
2. **Memory ceiling.** Even with a wider size field, a fixed slab costs
   `slabCapacity × alignUp(CellHeader + maxPayloadBytes, 8)`. Sizing every cell
   for the worst case (1 MiB × 1024 ≈ 1 GiB) is untenable. Oversized payloads
   are rare; pre-reserving for them is wasteful.

This plan ships **two complementary changes**:

| Part | Removes | Mechanism |
|------|---------|-----------|
| **1 — widen size fields** | the 64 KiB *type* ceiling | `uint16 → uint32` on cell + response-slot size fields |
| **2 — Variant B heap-spill** | the *preallocate-worst-case* memory cost | when a marshaled payload exceeds the cell, spill bytes to an `allocShared0` buffer referenced from the cell header; ring & free-list unchanged |

Part 1 lets you configure a genuinely large fixed cell (e.g. 1 MiB) when the
workload is uniformly large. Part 2 lets you keep cells modest and absorb the
occasional outlier on the heap. They stack.

---

## Part 1 — Widen size fields to `uint32`

### Type changes (`brokers/internal/mt_queue.nim`)

`CellHeader` (`~:270-275`) — replace the `uint16` size + pad with a `uint32`:

```nim
CellHeader* = object
  refcount*: Atomic[int]
  payloadSize*: uint32   # was uint16; `pad: uint16` removed
```

`ResponseSlotPool` slot header `ResponseSlotHeader` (`:374-377`) — widen
`payloadSize: uint16 → uint32`. The manual `pad: array[5, byte]` exists only to
align the following payload to 8; recompute it (state `uint8` at 0 + `uint32` at
4 ⇒ 8) or drop it and let `respSlotHeaderSize() = sizeof(ResponseSlotHeader)`
drive `slotStride` (`:409`). Also widen the two API signatures that carry this
field as `uint16`:

- `commitWrite(pool, idx, payloadSize: uint16)` (`:446`) → `uint32`.
- `payloadSize(pool, idx): uint16` getter (`:468`) → `uint32`.

`cellStride = alignUp(cellHeaderSize() + payloadBytes, 8)` (`~:303`) recomputes
from `sizeof` automatically; no hard-coded offsets exist. Confirm
`cellHeaderSize()` is `sizeof(CellHeader)` based (it is) so the layout shift is
transparent.

### Write/read sites to widen the cast

- `cell.payloadSize = uint16(written)` → `uint32(written)`
  (`mt_event_broker.nim:556`).
- Response commit in `mt_request_broker.nim` (`~:506-525`) — same cast.
- Request-message marshal commit (request slab cell) — same cast.
- Every **read** site that does `int(cell.payloadSize)` / `int(slot.payloadSize)`
  to size an unmarshal keeps working (widening is lossless); audit for any
  stray `uint16(...)` truncation on the read side.

### Guard the new range

`marshal` already refuses to overrun `cap` and returns `-1`
(`mt_codec.nim:115-116,122-123` → wrapper `:236-238`), so with a `uint32` size
there is no remaining silent-wrap path: `written` is bounded by `cellPayloadCap`
which is `uint32`.

**Verify:** a unit test that round-trips a payload in the 64 KiB–1 MiB range
through `EventBroker(mt, maxPayloadBytes = 2*1024*1024, slabCapacity = 4)` and
asserts byte-exact delivery (previously corrupted by the `uint16` wrap).

---

## Part 2 — Variant B heap-spill fallback

Keep the ring carrying a `uint32` cell index — **no ring or free-list change.**
Only the *payload bytes* spill; the slab cell remains the descriptor.

### CellHeader gains an overflow tag (`mt_queue.nim`)

```nim
CellHeader* = object
  refcount*: Atomic[int]
  payloadSize*: uint32    # inline byte count; 0 when spilled
  overflowLen*: uint32    # spilled byte count; 0 when inline
  overflow*: pointer      # allocShared0 buffer; nil on the fast path
```

Sentinel = `overflow != nil` (no magic size value). All POD, GC-free, lives in
the existing shared slab memory — safe under `--mm:refc` and `--mm:orc`, same
contract as the FFI CBOR lane.

### Size companion in the codec (`mt_codec.nim`)

The spill buffer must be allocated to exact size. Add a generated
`<type>MarshalSize(event): int` alongside the existing per-type marshaler — a
pure compute pass mirroring the marshal walk but counting bytes, no writes. This
avoids a marshal-into-growing-buffer retry loop.

### Write path — emit slow branch (`mt_event_broker.nim:544-556`)

Spill is **automatic** — there is no opt-in flag and no "forbidden" branch. When
a marshaled payload does not fit the fixed cell, it spills to the heap. The only
gate is the `maxDynamicPayloadBytes` ceiling, which is a *dev-chosen sanity cap*,
not a feature switch; its default is `high(uint32)` (effectively unbounded).

```nim
let written = try: marshal(payloadPtr, int(cellPayloadCap), event)
              except Exception: -1
if written >= 0:
  cell.payloadSize = uint32(written)          # fast path: fits the cell
else:
  let needed = marshalSize(event)             # spill path: heap buffer
  if uint64(needed) > uint64(cfg.maxDynamicPayloadBytes):
    error "event payload exceeds maxDynamicPayloadBytes",
      needed = needed, cap = cfg.maxDynamicPayloadBytes
    release(cellIdx, shardHint); return
  let buf = allocShared0(needed)
  if buf.isNil:                               # allocator refused (OOM)
    error "event payload spill alloc failed", needed = needed
    release(cellIdx, shardHint); return
  let w2 = marshalInto(buf, needed, event)
  if w2 < 0: deallocShared(buf); release(cellIdx, shardHint); return
  cell.overflow = buf
  cell.overflowLen = uint32(w2)
  cell.payloadSize = 0
```

The only paths that still drop are genuine failures — payload above the dev's
ceiling, allocator OOM, or a marshal error — not a "dynamic disabled" policy.

### Read path — dispatch/unmarshal

```nim
let (dataPtr, dataLen) =
  if not cell.overflow.isNil: (cell.overflow, int(cell.overflowLen))
  else: (cellPayloadPtr(cellIdx), int(cell.payloadSize))
unmarshal(dataPtr, dataLen, ...)
```

### Free — single chokepoint in `PayloadSlab.release` (`mt_queue.nim`)

**Verified against source:** `PayloadSlab.release` (`mt_queue.nim:335-338`) is
*only* ever called once a cell's refcount has reached 0 — the broker code calls
`decRefAndCheck` (`:343-347`) and invokes `release` only on the `true` return.
So `release` is the exact single chokepoint where a cell goes back to the
free-list. Free the overflow there (it reads `cellPtr(idx)` before the push),
covering **every** path — normal delivery, drop, error, dispatch failure:

```nim
proc release*(slab: var PayloadSlab, idx: uint32, shardHint: uint32) {.gcsafe.} =
  let cell = slab.cellPtr(idx)
  if not cell.overflow.isNil:
    deallocShared(cell.overflow); cell.overflow = nil; cell.overflowLen = 0
  push(slab.freeList, idx, shardHint)
```

`ResponseSlotPool.release` (`:434-435`) is the symmetric single return point for
a response slot (called by whichever side — requester-after-read or
provider-on-abandon — terminates the slot); add the same free there.

### Teardown — `deinitPayloadSlab` (`mt_queue.nim`) and the deferred-free path

`clearProvider`/shutdown can close a ring with in-flight cells still holding
spilled buffers (`mt_broker_common.nim:262-284` drains `PendingRingFree`).
`deinitPayloadSlab` must walk all cells and `deallocShared` any non-nil
`overflow` before freeing `storage`, else undelivered spilled payloads leak on
shutdown.

### RequestBroker symmetry

- **Request payload** rides the same `PayloadSlab`/`CellHeader` → inherits Parts
  1 & 2 for free.
- **Response** uses `ResponseSlotPool` (separate slot struct). Mirror the same
  three fields + spill on the "response too large" branch
  (`mt_request_broker.nim:506-525`), the same read-branch on the requester side,
  and the same free at slot release + pool deinit.

### Config (`brokers/internal/mt_config.nim`)

Add **one** field to `MtEvtCfg` and `MtReqCfg`:

| Field | Default | Meaning |
|-------|---------|---------|
| `maxDynamicPayloadBytes*: int` | `int(high(uint32))` (= 4 294 967 295) | Dev-chosen sanity cap on a single spilled payload. Default is effectively unbounded — spill is always available. A payload above this is dropped (event) / `err`-ed (request) as an OOM/DoS backstop only. The dev may set it lower for a hard guardrail. |

- Spill itself has **no flag** — it is automatic whenever the marshaled payload
  exceeds the fixed cell. `maxDynamicPayloadBytes` only bounds *how large* a
  single spill may get.
- Thread the one kwarg through the macro kwarg parser and emit it as a lit next
  to the existing `queueDepth/slabCapacity/...` lits
  (`mt_event_broker.nim:158-161`, `mt_request_broker.nim:238-243`).
- `cell.overflowLen` / `cell.payloadSize` are `uint32`, so a single spilled
  payload is intrinsically capped at `high(uint32)` ≈ 4 GiB regardless of the
  config value — keep `maxDynamicPayloadBytes` an `int` but clamp/validate it
  against `high(uint32)` at macro time.

---

## Why this is memory-model safe (refc + orc)

| Concern | Resolution |
|---------|-----------|
| Cross-thread ownership | `overflow` is `allocShared0` POD bytes; producer allocates, consumer/last-release frees via `deallocShared`. Single ownership transfer through the queue — identical to the proven FFI CBOR courier and to the slab `storage` itself. |
| GC interaction | No GC-managed type crosses the thread boundary; marshaled bytes are flat. Behaves identically under `--mm:refc` and `--mm:orc`. |
| Leaks / use-after-free | Free centralized in `release()` (covers all delivery/drop/error paths) + `deinitPayloadSlab` (covers shutdown with in-flight cells). |
| Backpressure | `queueDepth` still bounds message *count*; spill only relaxes per-message *size*. `maxDynamicPayloadBytes` (default `high(uint32)`) is the only spill cap. |
| Invariant I0 relaxation | I0 ("hot path never calls a Nim allocator") **no longer holds for the spill branch** — an oversized emit/request now calls `allocShared0` on the producer thread, and `release` calls `deallocShared` on the consumer thread. This is an accepted, deliberate trade: the common (fits-the-cell) path is byte-for-byte unchanged and allocator-free; only the rare oversized path allocates. Update the I0 comment in `mt_queue.nim:7-11` to document the spill carve-out rather than claim an absolute. |

## Blast radius

- `payloadSize`, `CellHeader`, `PayloadSlab`, `ResponseSlotPool` are **internal**
  to the MT lane (defined in `mt_queue.nim`, read/written only by generated code
  in `mt_event_broker.nim` / `mt_request_broker.nim`). Not part of the public
  broker API and **not** part of the FFI C ABI.
- The FFI/CBOR lane is independent and untouched.
- **Pre-edit gate (per CLAUDE.md):** run `npx gitnexus analyze` (index was
  quiet/stale this session), then `gitnexus_impact` on `CellHeader`,
  `PayloadSlab`, `ResponseSlotPool`, `payloadSize`; report blast radius before
  editing. Run `gitnexus_detect_changes()` before commit.

---

## Step sequence (each with its verify gate)

1. **Part 1 — widen to `uint32`** → verify: new 64 KiB–2 MiB round-trip test
   passes; `nimble test` green on orc+refc, debug+release.
2. **Codec `marshalSize` companion** → verify: `marshalSize == marshal`'s
   `written` for a spread of types (unit assert).
3. **Part 2 — EventBroker spill** (header fields, write/read/release/deinit,
   config + kwargs) → verify: oversized event delivered byte-exact with
   `allowDynamicPayload = true`; dropped+logged with it `false`; dropped above
   `maxDynamicPayloadBytes`.
4. **Part 2 — RequestBroker spill** (request slab inherits; response pool
   mirrored) → verify: oversized request and oversized response both round-trip.
5. **Memory diagnostics** → verify: ASAN (clang) + refc build clean on a
   spill-heavy run; valgrind/memcheck no leaks (CLAUDE.md mandate for
   lifetime-touching changes).
6. **Regression / perf** → verify: `nimble perftest` fast path (no spill)
   unchanged vs. baseline (`doc/design/bench_baseline.md` ~615 ns no-overflow);
   `nimble nphall` formatting; full CI task list green.

## Open questions to confirm at implementation time

- Exact signature of `PayloadSlab.release` / `ResponseSlotPool.release` (where
  the `refcount → 0` transition is observed) — that is the free chokepoint.
- Whether `largePayload` should default `allowDynamicPayload = true` or leave it
  an explicit opt-in for all presets.
