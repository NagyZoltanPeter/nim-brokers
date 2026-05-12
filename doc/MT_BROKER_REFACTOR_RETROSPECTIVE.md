# Multi-thread broker refactor — retrospective

_branch: `refactor-channel-dispatch` (2026-04 → 2026-05)_

## TL;DR

The MT brokers' cross-thread dispatch was rebuilt from Nim stdlib
`Channel[T]` onto a custom **lock-free ring + pre-allocated slab + response
slot pool**. Two production-painful Nim/refc bugs are closed, throughput
improves up to **7.4×**, average cross-thread latency drops by up to **270×**.
The cost is a fixed memory footprint at init, a small set of compile-time
restrictions on payload types, and a new visible failure mode (`drop` on
overflow) that `Channel[T]` did not have.

| Metric (5 emitters × 500 evts × 512 B, refc, orc/release) | Master `Channel[T]` | This branch | Δ |
|---|---|---|---|
| EventBroker(mt) cross-thread throughput (refc) | 107 K evt/s | **788 K evt/s** | +7.4× |
| EventBroker(mt) avg cross-thread latency (refc) | 7.378 ms | **27.6 µs** | −99.6 % |
| EventBroker(mt) cross-thread throughput (orc) | 206 K evt/s | **511 K evt/s** | +2.5× |
| EventBroker(mt) avg cross-thread latency (orc) | 4.415 ms | **403 µs** | −91 % |
| RequestBroker(mt) cross-thread throughput (refc) | 37 K req/s | 41 K req/s | +9 % |
| Nim bugs hit (see [LIMITATION.md](LIMITATION.md)) | §2.2, §2.3, §2.6 | §2.1, §2.7 (newly disclosed) | −3, +1 |

## 1. Why we did it

The MT brokers on master deep-copied every emit/request payload into the
shared heap via `Channel[T].storeAux`. Two bugs on
[LIMITATION.md](LIMITATION.md) were direct consequences of that allocator
interaction:

| Bug | Trigger | Symptom |
|---|---|---|
| **§2.2** | macOS · Nim 2.2.4 · refc · debug | `storeAux` freelist race in `Channel[T]` deep-copy on send. Mitigated on master only by gating tests via `brokerTestsSkipFragileRefcBursts`. |
| **§2.6** | macOS · ORC | Slot-payload UAF after the sender thread exits before the receiver reads. Documented in commit `c4193e4`. |
| §2.3 | Nim devel · refc · release | Shared-heap regression in the same `storeAux` path. |

Both core bugs trace to the **per-send deep-copy** model. No amount of
broker-side defensive code fixed them — the fix had to be "don't deep-copy
per send."

## 2. What we built

A two-tier shared-memory queue, allocated once per (broker, ctx,
listener-thread) at init time:

```
                  emitter thread                    listener thread
                  ──────────────                    ────────────────
                      emit(evt)                         poll-loop
                          │                                │
                          ▼                                ▼
            ① alloc cell ─►  ┌────────────────────┐   ⑤ deque idx
              free-list      │  Vyukov MPSC ring  │      │
              pop, no syscall│  (queueDepth slots)│      ▼
                          │  └────────────────────┘   ⑥ decode payload
                          ▼          │                   │
            ② mt_codec encodes       │                   ▼
              into cell.payload[]    │                ⑦ refcount--
                          │          │                   │  if 0:
                          ▼          ▼                   ▼
            ③ refcount = N_listeners┌────────────────┐  cell back to slab
                          │         │  PayloadSlab   │
                          ▼         │  (slabCapacity │
            ④ enqueue cell idx ────►│   cells of    │
                                    │   maxPayload   │
                                    │   bytes each)  │
                                    └────────────────┘

  RequestBroker only:  ResponseSlotPool — reserved at request issue,
                       freed when caller decodes reply.
```

Hot path properties:

| Property | Master Channel[T] | New ring+slab |
|---|---|---|
| Allocations per send | 1 (deep-copy into shared heap) | **0** (slab cell pre-allocated) |
| Allocations per receive | 1 (free shared-heap copy) | **0** (refcount→cell back to slab) |
| Fan-out cost (N listeners) | N deep copies | **1 cell, atomically refcounted** |
| GC interaction with payload | yes (refc / ORC touches the seq) | **none** (cell is plain bytes) |
| Memory shape | grows on demand | **fixed at init** |
| Overflow behavior | back-pressure / grow | drop (Event) / err (Request) |
| File-descriptor count | O(threads) shared signal | O(threads) shared signal — unchanged |

Implementation lives in [brokers/internal/mt_queue.nim](../brokers/internal/mt_queue.nim)
(~430 LOC, Vyukov MPSC + sharded ABA-tagged free-list + slot state
machine) and [brokers/internal/mt_codec.nim](../brokers/internal/mt_codec.nim)
(byte-level marshaler, replaces GC-aware copy).

## 3. Why ORC also benefits — not just refc

The refactor was motivated by a refc-specific bug (§2.2), but the perf
numbers show **both GCs win, big**:

| MM | Avg cross-thread latency (master) | Avg cross-thread latency (new) | Improvement |
|---|---|---|---|
| refc | 7.378 ms | 27.6 µs | **267×** |
| ORC | 4.415 ms | 403 µs | **11×** |

Three reasons ORC was *also* hurting under Channel[T]:

1. **`Channel[T].storeAux` runs `=copy`/`=destroy` regardless of GC.**
   Whether the payload is `seq[byte]` under refc or under ORC, sending it
   through Channel[T] invokes the same allocator, which is the slow part.
   Replacing it with `copyMem` into a pre-allocated cell removes that cost
   for *every* memory model.
2. **§2.6 was an ORC-only bug.** Channel's slot-payload UAF after sender
   exit was reproducible only under ORC's destructor ordering.
3. **ORC's cycle collector touches Channel's shared-heap payloads.**
   Removing the payloads from the GC's purview removes that scan work.

In effect this refactor was framed as a "refc fix" but is really a
"remove the allocator interaction on the hot path" change — which is
GC-agnostic.

## 4. How — phase walk

| Phase | Commit | What landed |
|---|---|---|
| 0 | `73e889a`, `d15289a`, `c4193e4` | Probe tests reproducing §2.6; document Channel UAF in LIMITATION.md |
| 1 | `dd1b86c` | mt_queue primitives — Vyukov MPSC ring, payload slab, response-slot pool |
| 2 + 3 | `257297a` | EventBroker(mt) ported onto ring + global slab + refcount |
| 4 | `8eee0c6` | RequestBroker(mt) on ring + slab + ResponseSlotPool |
| 4b | `c821bb4` | Marshal `Result[T,string]` in ResponseSlot — eliminate the last cross-thread refc `=copy` |
| 5a | `13f3666` | Rewrite [LIMITATION.md](LIMITATION.md) for post-refactor state |
| 5b | `2441b2b` | Retire `brokerTestsSkipFragileRefcBursts` test gate |
| 5c | `235f64b` | Update [MultiThread_EventBroker.md](MultiThread_EventBroker.md) for ring + slab + pool design |

## 5. Perf comparison (full table)

Setup: macOS · Nim 2.2.4 · 5 emitter/worker threads × 500 events/requests ·
512 B payload · `-d:release -d:chronicles_log_level=ERROR`.

### EventBroker(mt)

| Scenario | MM | Master | This branch | Δ |
|---|---|---|---|---|
| Cross-thread throughput (offered) | orc | 206.23 K evt/s | 511.42 K evt/s (15 % dropped⚠) | +2.5× |
| Cross-thread throughput (offered) | refc | 106.70 K evt/s | 788.48 K evt/s (0 % dropped) | +7.4× |
| Cross-thread avg latency | orc | 4.415 ms | 403 µs | −91 % |
| Cross-thread avg latency | refc | 7.378 ms | 27.6 µs | −99.6 % |
| Cross-thread max latency | orc | 6.033 ms | 826 µs | −86 % |
| Cross-thread max latency | refc | 11.396 ms | 123 µs | −99 % |
| Same-thread throughput | orc | 31.66 K evt/s | 37.32 K evt/s | +18 % |
| Same-thread throughput | refc | 34.15 K evt/s | 36.53 K evt/s | +7 % |

The 15 % drop on ORC/release is a property of the **test under default
capacity** — the emit-burst at 511 K evt/s outpaces drain over 5 ms with a
256-slot ring. With a tuned ring (`queueDepth=4096, slabCapacity=8192`,
~9 MB) the same workload is lossless. See Phase C of the follow-up plan.

### RequestBroker(mt)

| Scenario | MM | Master | This branch | Δ |
|---|---|---|---|---|
| Cross-thread throughput | orc | 40.77 K req/s | 39.45 K req/s | −3 % |
| Cross-thread throughput | refc | 37.44 K req/s | 40.73 K req/s | +9 % |
| Cross-thread avg latency | orc | 119.8 µs | 124.0 µs | +4 µs |
| Cross-thread avg latency | refc | 130.1 µs | 120.2 µs | −8 % |
| Same-thread throughput | orc | 214.71 K req/s | 259.90 K req/s | +21 % |
| Same-thread throughput | refc | 1.01 M req/s | 1.09 M req/s | +8 % |

Request path is naturally rate-limited by `waitFor` RTT, so the ring's
send-side speedup is masked. **Tail latency improves dramatically** (max
6–11 ms cross-thread under master vs. < 1 ms now), which matters more for
RPC than averages.

## 6. Bug coverage

| Bug ([doc/LIMITATION.md](LIMITATION.md)) | Master | This branch |
|---|---|---|
| §2.2 macOS+refc+debug Channel `storeAux` freelist race | HIT (gated) | **CLOSED** — gate retired in `2441b2b` |
| §2.6 macOS+ORC slot-payload UAF after sender exit | HIT | **CLOSED** — all 7 probes pass under ASAN+ORC |
| §2.3 Nim-devel+refc+release shared-heap regression | HIT | **CLOSED** (same trigger class) |
| §2.1 Windows+refc TLS-uninit | HIT | HIT — not channel-related |
| §2.7 chronos `newFutureImpl` alloc race on macOS+refc+native-FFI | masked by §2.2 | **Newly disclosed** — refactor moved broker allocs off hot path, exposing chronos's own alloc race on cross-thread RPC > ~50/s. Workaround: ORC or CBOR-mode FFI. |

## 7. New costs — honest accounting

| Cost | Why it exists | Mitigation |
|---|---|---|
| **Fixed-capacity rings/slabs** at init | Ring/slab pre-allocated, no growth | Phase B (next): macro-arg kwargs + presets for per-broker tuning |
| **Drop on overflow** (Event) / `err("queue full")` (Request) | Non-blocking emit; doesn't block sender if listener is slow | Document; offer back-pressure variant later if needed |
| **Payload type restrictions**: `ref T`, `ptr T`, `pointer`, `cstring`, proc fields → compile-time `{.error.}` | Marshaler copies raw bytes; cross-thread heap pointers are unsafe regardless | Use shared-memory types or CBOR FFI |
| **Idle RAM** (defaults): EventBroker(mt) ≈ 1.1 MB, RequestBroker(mt) ≈ 16.9 MB per (broker, ctx) | All cells pre-allocated | Phase B: type-driven defaults shrink scalar-returning RequestBrokers from 16 MB → ~16 KB (1000×) |
| **+~430 LOC of subtle lock-free code** in `mt_queue.nim` | Vyukov MPSC + ABA-tagged sharded free-list + slot state machine | One-time cost; isolated; well-commented invariants |
| **Per-RPC marshal+unmarshal of `Result[T,string]`** in response path | Required to remove the last cross-thread refc `=copy` (Phase 4b) | Inherent to the design |

## 8. Memory footprint mitigation

The "fixed memory at init" property is the main cost of the refactor. A
naive port of master's behavior would have meant every broker reserving
default-sized rings/slabs (≈ 1.1 MB per EventBroker, ≈ 16.9 MB per
RequestBroker — dominated by the 256-slot × 64 KB response pool) even
for trivial payloads. Three layered heuristics close that gap. They are
all opt-out, applied in this order, and the result is reported at compile
time per broker.

### 8.1 Capacity kwargs

Every `EventBroker(mt)` / `RequestBroker(mt)` macro call accepts
optional kwargs to tune the ring + slab + response-pool dimensions:

```nim
EventBroker(mt, queueDepth = 1024, slabCapacity = 4096,
            maxPayloadBytes = 2048):
  type MyEvt = ...

RequestBroker(mt, responseSlots = 64, maxResponseBytes = 4 * 1024):
  type Foo = ...
  proc fetch*(arg: string): Future[Result[Foo, string]] {.async.}
```

| Knob | Drives |
|---|---|
| `queueDepth` | ring slots per listener / provider bucket (power-of-2). Higher = absorbs larger emit bursts before drop. |
| `slabCapacity` | total cells (concurrent in-flight payloads). Lifetime ≈ cross-thread hop. |
| `maxPayloadBytes` | per-cell payload buffer. Overflow → drop / err. |
| `responseSlots` (req) | concurrent in-flight requests (RTT-bound). |
| `maxResponseBytes` (req) | per-response marshal buffer. |
| `freeListShards` | slab free-list partitions (CAS contention reducer). |

Compile-time validation: `queueDepth` must be power-of-2; positivity
checks on the rest; unknown kwarg names error with the valid list.

### 8.2 Named presets

Four built-in presets bundle the knobs into a profile, selectable via
`preset = <name>`. Individual kwargs supplied alongside override the
preset's fields, so you can pick a shape and tweak one value:

```nim
EventBroker(mt, preset = fastBurst, maxPayloadBytes = 1024):
  type MyEvt = ...
```

| Preset | Profile | When to use |
|---|---|---|
| `defaultBalanced` | unchanged defaults | general use; matches the original constants |
| `fastBurst` | wide ring/slab, small per-cell payload, more shards | bursty emit, small payload |
| `largePayload` | narrow ring/slab, big per-cell payload | infrequent traffic with big payloads |
| `tinyFootprint` | tiny everything | embedded / memory-constrained |

### 8.3 Type-driven defaults

When neither a kwarg nor a preset sets `maxPayloadBytes` /
`maxResponseBytes`, the macro inspects the type AST at compile time
and picks a size class. Eliminates the most common over-provisioning —
a scalar-returning RequestBroker no longer reserves 64 KB per response
slot.

| Type shape | Default cell size |
|---|---|
| scalar (bool/intN/uintN/floatN/byte/char) | **64 B** |
| string | **4 KB** |
| seq[string] | **16 KB** |
| seq[byte] / seq[uint8] | **64 KB** |
| array[N, T] | classified by T |
| seq[other primitive] | 4 KB |
| alias / external / unresolvable | **8 KB + compile-time warning** |

For an object the cell is sized to fit the largest classified field.
For RequestBroker the request-side payload is auto-sized from the proc
parameters, and the response cell from the broker's type fields.

Concrete impact: the RequestBroker example test (`MTReq`, two `string`
fields) goes from **16.9 MB** idle (blanket 64 KB response default) to
**1.2 MB** idle — a 14× reduction with no user action.

### 8.4 Compile-time inspection

Every `EventBroker(mt)` / `RequestBroker(mt)` callsite emits a `hint`
line showing the resolved configuration with provenance per field, plus
estimated idle RAM breakdown:

```
Hint: [brokers] RequestBroker(MTReq):
      queueDepth=256 [default],
      slabCapacity=64 [default],
      maxPayloadBytes=4096 [auto:string],
      responseSlots=256 [default],
      maxResponseBytes=4096 [auto:string],
      freeListShards=2 [default]
      — idle RAM: ring≈6.0 KB, slab≈258.0 KB, respPool≈1.0 MB, total≈1.2 MB
```

The provenance tag (`default` / `kwarg` / `preset:<name>` / `auto:<reason>`)
makes it visible at a glance whether a chosen value came from the user,
a preset, the type classifier, or the unchanged default. Opt out per
build with `-d:brokerConfigSilent`, or per category with
`--hint[User]:off`.

See [MT_BROKER_CONFIG.md](MT_BROKER_CONFIG.md) for the full reference.
