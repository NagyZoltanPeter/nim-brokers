# Multi-thread broker configuration

Reference for tuning `EventBroker(mt)` and `RequestBroker(mt)` capacity,
payload sizing, and idle memory footprint.

> See also: [MT_BROKER_REFACTOR_RETROSPECTIVE.md](MT_BROKER_REFACTOR_RETROSPECTIVE.md)
> §8 for the design rationale and the memory-mitigation heuristics this
> document references.

## 1. Quick start

If you don't need to think about it: don't. The macros pick reasonable
defaults from your broker's type shape. The compile-time `hint` line
will tell you what was chosen and how much RAM the broker reserves at
init.

When you do need to tune — bursty workloads, large payloads, embedded
targets — there are three composable mechanisms:

| Mechanism | When to reach for it |
|---|---|
| `preset = <name>` | one of the named profiles fits your case |
| `<knob> = <value>` kwargs | preset close enough, but a field needs override |
| neither | default sizing — the type-driven heuristic does the work |

All three may be combined. Resolution order is: **defaults → preset →
kwargs → type-driven auto for unset payload size fields.**

## 2. The two-tier queue (and why these knobs exist)

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

  RequestBroker only:  ResponseSlotPool — `responseSlots` cells of
                       `maxResponseBytes` payload. Reserved at request
                       issue, freed on caller-side decode.
```

Each macro call reserves all three structures up-front (per `(broker,
context, listener-thread)`). No allocation on the hot path.

## 3. Knob reference

### EventBroker(mt)

| Knob | Default | Drives | Drop trigger | RAM cost |
|---|---|---|---|---|
| `queueDepth` | 256 | Ring slots (must be power-of-2) | bursty emit briefly outpacing the listener → ring full | `~24 B/slot` |
| `slabCapacity` | 1024 | Total cells = concurrent payloads alive (cell lifetime ≈ cross-thread hop + listener async work) | slow listener holds many cells → slab exhausted | `1 × cellStride` per cell |
| `maxPayloadBytes` | type-driven | Per-cell payload buffer (`cellStride = sizeof(header) + maxPayloadBytes`, aligned to 8) | marshaled event too large for the cell | direct multiplier on slab RAM |
| `freeListShards` | 4 | Slab free-list shards. More = less CAS contention between concurrent emitters | almost never matters below 16 threads | `~16 B per shard` |

Total event-broker idle RAM ≈
`queueDepth × 24 + slabCapacity × align8(headerBytes + maxPayloadBytes)`.

### RequestBroker(mt)

| Knob | Default | Drives | Failure mode | RAM cost |
|---|---|---|---|---|
| `queueDepth` | 256 | Ring slots for request messages to the provider | bursty requests outpace provider | `~24 B/slot` |
| `slabCapacity` | 64 | Cells for in-flight request payloads (lifetime ≈ cross-thread hop only — the provider releases the cell as soon as it has decoded the args, *before* doing the work) | highly concurrent fan-out from caller | `1 × cellStride` per cell |
| `maxPayloadBytes` | type-driven (proc params) | Per-request marshal buffer | large request args → encode fails → `err` | multiplier on slab RAM |
| `responseSlots` | 256 | Concurrent **outstanding** requests (slot held caller-side from request issue until reply is decoded — RTT-bound). | more than `responseSlots` in-flight at once | `1 × slotStride` per slot |
| `maxResponseBytes` | type-driven (broker type) | Per-response marshal buffer | large reply → encode fails | multiplier on responseSlots RAM |
| `freeListShards` | 2 | Same as event | rarely matters | `~16 B per shard` |

Total request-broker idle RAM ≈
`queueDepth × 24 + slabCapacity × align8(headerBytes + maxPayloadBytes) +
responseSlots × align8(slotHeaderBytes + maxResponseBytes)`.

### Sizing intuition

| Knob | Rough rule |
|---|---|
| `queueDepth` | `expected_burst_rate × hop_time_µs / 1_000_000`, rounded up to power-of-2. Cheap to over-provision (24 B/slot). |
| `slabCapacity` | similar — recycle is fast (microseconds), so even bursty workloads do fine with O(1000). |
| `responseSlots` | matches your **concurrent-in-flight** ceiling. RTT-bound, slow to recycle. |
| `maxPayloadBytes` / `maxResponseBytes` | upper bound on a single marshaled payload. Leave on default and let the type classifier size it. |
| `freeListShards` | leave alone unless profiling shows CAS contention. |

## 4. Type-driven default sizing

When `maxPayloadBytes` / `maxResponseBytes` is left at its default the
macro inspects the type AST at compile time and picks a size class.
The classifier walks the type recursively — an `Option[T]` recurses
into `T`, an `array[N, T]` recurses into `T` — so the bucket reported
in the compile-time hint always reflects the worst-case wire-bound
payload, never an arbitrary outer-bracket fallback.

| Type shape | Auto cell size | Origin tag emitted |
|---|---|---|
| scalar (`bool`, `int*`, `uint*`, `float*`, `byte`, `char`) | **64 B** | `auto:scalar` (object body) / `auto:scalar:<name>` (bare type) |
| `string` | **4 KB** | `auto:string` |
| `seq[byte]` / `seq[uint8]` | **64 KB** | `auto:seq[byte]` |
| `seq[string]` | **16 KB** | `auto:seq[string]` |
| `seq[<other primitive>]` | 4 KB | `auto:seq[<T>]` |
| `array[N, T]` | bucket of `T` (recursive) | inherits T's origin |
| `Option[T]` | bucket of `T` (recursive) | `auto:Option[<inner-reason>]` |
| `Option[seq[byte]]` | **64 KB** (= inner `seq[byte]`) | `auto:Option[seq[byte]]` |
| `Option[scalar]` | **64 B** | `auto:Option[scalar:<name>]` |
| `void` / zero-field body | **64 B** (envelope only) | `auto:void` |
| inline `object` | max over classified fields | inherits dominant field's origin |
| alias / external / unresolvable | **8 KB + compile-time warning** | `auto:unclassifiable:<repr>` |

For an `object` type the cell is sized to fit the largest classified
field (`classifyFieldsMax`).

`void`-bodied brokers — typed as `type Foo = void` for an event, or a
zero-arg `proc signature*(): Future[Result[Foo, string]]` paired with
`type Foo = void` for a request — collapse to the **scalar bucket
(64 B)** rather than the conservative 1 KB / 64 KB safety default.
A payload-less notification only ships the CBOR envelope, so a
larger cell would pin idle slab/respPool memory for no reason. For a
single zero-field `RequestBroker(mt): type X = void` this is the
difference between **40 KB and 16 MB idle RAM per context**.

`Option[T]` recurses into `T` rather than falling into the
`unclassifiable` bucket. This is both more accurate and safer:
without the recursion `Option[seq[byte]]` silently under-allocated
to 8 KB while its inner `seq[byte]` can carry 64 KB, which would
surface as a runtime cell-too-small error rather than a clean
compile-time hint.

When the classifier emits a warning it means it could not introspect
the type (typically because it's an alias to a non-primitive, or a
forward-declared external type). The build still succeeds with an
8 KB fallback, but you should provide `maxPayloadBytes = N` /
`maxResponseBytes = N` explicitly so the size matches your actual
payload. The fix is usually one line:

```nim
# `Address` is an external object — classifier can't introspect it
EventBroker(mt, maxPayloadBytes = 256):
  type Connected = object
    peer*: Address
```

## 5. Presets

Built-in profiles for the most common shapes. Selected via
`preset = <name>` in the macro kwargs.

| Preset | EventBroker(mt) | RequestBroker(mt) |
|---|---|---|
| `defaultBalanced` | ring=256, slab=1024, payload=1 KB, shards=4 | ring=256, slab=64, payload=1 KB, respSlots=256, respBytes=64 KB, shards=2 |
| `fastBurst` | ring=4096, slab=8192, payload=256, shards=8 | ring=4096, slab=256, payload=256, respSlots=1024, respBytes=4 KB, shards=4 |
| `largePayload` | ring=64, slab=128, payload=64 KB, shards=2 | ring=64, slab=32, payload=64 KB, respSlots=64, respBytes=256 KB, shards=2 |
| `tinyFootprint` | ring=32, slab=32, payload=256, shards=1 | ring=16, slab=8, payload=256, respSlots=16, respBytes=1024, shards=1 |

Individual kwargs supplied alongside the preset override the preset's
fields:

```nim
EventBroker(mt, preset = fastBurst, maxPayloadBytes = 1024):
  type MyEvt = ...
```

> User-defined presets (passing an external const struct) are planned
> but not yet implemented. The kwarg parser emits a clear error if you
> try to pass a non-built-in preset name.

## 6. Compile-time inspection

Every MT broker macro callsite emits a `hint` line. Example for the
event-broker performance test:

```
Hint: [brokers] EventBroker(PerfEvt): queueDepth=4096 [preset:fastBurst],
                                       slabCapacity=8192 [preset:fastBurst],
                                       maxPayloadBytes=1024 [kwarg],
                                       freeListShards=8 [preset:fastBurst]
                — idle RAM: ring≈96.0 KB, slab≈8.2 MB, total≈8.3 MB
```

The provenance tag `[origin]` per field:

| Tag | Meaning |
|---|---|
| `default` | unchanged from the module's default |
| `kwarg` | explicit `<knob> = <value>` in the macro call |
| `preset:<name>` | inherited from a `preset = <name>` kwarg |
| `auto:<reason>` | derived by the type-driven default. Examples: `auto:scalar` (object body whose biggest field is a scalar) / `auto:scalar:int64` (bare scalar type at classifier root) / `auto:string` / `auto:seq[byte]` / `auto:seq[string]` |
| `auto:void` | broker body is `type X = void` or has zero fields — cell collapsed to the 64 B scalar bucket (envelope only) |
| `auto:Option[<inner-reason>]` | `Option[T]` — recursed into T and inherited its bucket (e.g. `auto:Option[seq[byte]]` = 64 KB, `auto:Option[scalar:int64]` = 64 B) |
| `auto:unclassifiable:<...>` | fallback for a type the classifier couldn't resolve — pair with a compile-time `{.warning.}` |

Idle RAM is an estimate (per-element bytes are approximate and exclude
the small fixed overhead of the broker's bucket / global lock). Use it
to compare configurations and catch surprises — the exact value depends
on alignment and may differ by a few percent from `top`.

To silence the line per build: `-d:brokerConfigSilent`.
To silence the entire User category: `--hint[User]:off`.

## 7. Examples

### Default, scalar event (uses the type classifier)

```nim
EventBroker(mt):
  type Tick = object
    timestampNs*: int64
    seqNum*: uint32

# Hint: [brokers] EventBroker(Tick): queueDepth=256 [default],
#       slabCapacity=1024 [default], maxPayloadBytes=64 [auto:scalar],
#       freeListShards=4 [default]
#       — idle RAM: ring≈6.0 KB, slab≈92.0 KB, total≈98.0 KB
```

### Notification-only (void) event — minimal RAM footprint

```nim
EventBroker(mt):
  type Heartbeat = void

# Hint: [brokers] EventBroker(Heartbeat): … maxPayloadBytes=64 [auto:void] …
#       — idle RAM: total≈102.0 KB
```

The same shape applies to a notification-only request:

```nim
RequestBroker(mt):
  type Ack = void
  proc signature*(): Future[Result[Ack, string]] {.async.}

# Hint: [brokers] RequestBroker(Ack): maxPayloadBytes=64 [auto:void],
#       maxResponseBytes=64 [auto:void] … — idle RAM: total≈40.0 KB
```

Without the `auto:void` collapse this would pin **16 MB** for the response
pool of every notification-style RequestBroker.

### Optional field — sized by the inner type, not by the `Option` wrapper

```nim
import std/options

EventBroker(mt):
  type ChunkReady = object
    blob*: Option[seq[byte]]    # → auto:Option[seq[byte]] = 64 KB
    label*: string              # → auto:string = 4 KB
# The object bucket = max(64 KB, 4 KB) = 64 KB.
# Hint: maxPayloadBytes=65536 [auto:Option[seq[byte]]]
```

Compare to before the fix: `Option[seq[byte]]` fell into the
`unclassifiable` arm at 8 KB — too small for the wire-bound 64 KB,
so a large emit would have returned `err(...)` at runtime. The
recursive `Option[T]` classification eliminates that failure mode.

### Bursty event broadcast with a preset and a payload override

```nim
EventBroker(mt, preset = fastBurst, maxPayloadBytes = 1024):
  type WireEvent = object
    payload*: seq[byte]
```

### Request broker for an RPC returning binary blobs

```nim
RequestBroker(mt, preset = largePayload, responseSlots = 32):
  type FetchResult = object
    blob*: seq[byte]
  proc fetch*(key: string): Future[Result[FetchResult, string]] {.async.}
```

### Memory-constrained environment

```nim
EventBroker(mt, preset = tinyFootprint):
  type LedToggle = object
    on*: bool
```

## 8. Failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| Chronicles `WRN event dropped: listener queue full` | Burst emit rate > listener drain rate over the ring's depth | bump `queueDepth` and/or `slabCapacity`; or pick `preset = fastBurst` |
| `RequestBroker(...): provider queue full` error returned | Same as above on the request path | bump `queueDepth`, or throttle issue rate |
| `RequestBroker(...): no response slot available` error | More concurrent in-flight requests than `responseSlots` | bump `responseSlots` to match your concurrency ceiling |
| Compile-time `unclassifiable:<name>` warning | Type classifier couldn't introspect an alias / external type | provide explicit `maxPayloadBytes = N` / `maxResponseBytes = N` |
| Idle RAM higher than expected | Auto-classified large field (e.g. `seq[byte]` → 64 KB cells × 1024 slab) | use `preset = largePayload` (narrows slab) or explicit `slabCapacity` |

## 9. Planned: Tier-A scalar inline (not yet implemented)

A future optimization for brokers whose entire payload fits in a single
ring slot — typically the "tick / heartbeat / counter / flag" pattern
that makes up an estimated 40–50 % of real-world MT brokers.

### Idea

For event types whose payload is one scalar field (≤ 16 B — `int64`,
`uint32`, `bool`, enum, `distinct` of a scalar), the value would live
**directly in the ring slot**, with no payload slab and no marshaler
involvement.

### Today vs. Tier-A

| Step | Today (slab path) | Tier-A (inline) |
|---|---|---|
| Send | alloc slab cell → marshal into cell → enqueue `cellIdx: uint32` → bump refcount | tryEnqueue value into ring |
| Receive | dequeue idx → load cell → unmarshal → call handler → decRef → release to slab | tryDequeue value → call handler |
| Idle RAM | ring + slab (~100 KB at defaults) | ring only (~6 KB at defaults) |
| Per-event cost | ~5 atomics + 2 memcpy + slab claim/release | 1 enqueue + 1 dequeue |

### Why it's not free to implement

The `VyukovMpscRing[T]` primitive in [mt_queue.nim](../brokers/internal/mt_queue.nim) is
already generic over `T`, so the queue itself supports Tier-A. The
implementation cost is in the **broker generator**, which today is
~700 LOC tightly coupled to the slab/refcount model:

- The `CtrlClearListeners = high(uint32) - 1` sentinel is multiplexed
  onto the same ring as event payloads
  ([mt_event_broker.nim:50](../brokers/internal/mt_event_broker.nim)). When the
  ring's `T` is the event type instead of `uint32`, the sentinel must
  move to a separate `Atomic[bool] needsClear` channel.
- Emit / listener / drop code paths all assume cell allocation,
  marshal/unmarshal, and refcounted release; each would need a parallel
  inline-mode body.

Cleanest approach: a parallel `generateMtEventBrokerTierA(body, cfg)`
generator (~350–450 LOC), with the existing macro dispatching to it
when `cfg.tierA` is set.

### Detection

At macro time, set `cfg.tierA = true` when:

- The broker type is an `object` with exactly one scalar field, **or**
- The broker type is a `distinct` / alias of a scalar, **or**
- (Optional, broader) The broker type is a small object whose total
  size is ≤ 16 B and every field is scalar.

When detected, also force `slabCapacity` / `maxPayloadBytes` / related
slab-only knobs to be moot (and surface that in the compile-time hint
as `[tier-a:inline]`).

### Estimated impact

For an event broker carrying a single `int64`:

| | Defaults today | Tier-A |
|---|---|---|
| Idle RAM | ~98 KB | ~6 KB (16×) |
| Per-event allocator interaction | slab claim + release | none |
| Per-event atomics | ~5 | ~2 |

Cross-thread throughput would benefit by an estimated 2–3× on
purely-scalar brokers (no measurement yet — predictive based on
removing the slab claim / refcount round-trip from the hot path).

### Status

Deferred. The detection + flag wiring is a small follow-on; the
generator work is a dedicated mini-project of its own and should be
scoped + reviewed separately. No timeline committed.
