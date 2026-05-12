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
macro inspects the type AST at compile time and picks a size class:

| Type shape | Auto cell size |
|---|---|
| scalar (`bool`, `int*`, `uint*`, `float*`, `byte`, `char`) | **64 B** |
| `string` | **4 KB** |
| `seq[string]` | **16 KB** |
| `seq[byte]` / `seq[uint8]` | **64 KB** |
| `array[N, T]` | classified by `T` |
| `seq[<other primitive>]` | 4 KB |
| alias / external / unresolvable | **8 KB + compile-time warning** |

For an `object` type the cell is sized to fit the largest classified
field.

When the classifier emits a warning it means it could not introspect
the type (typically because it's an alias or a forward-declared external
type). The build still succeeds with an 8 KB fallback, but you should
provide `maxPayloadBytes = N` / `maxResponseBytes = N` explicitly so
the size matches your actual payload.

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
| `auto:<reason>` | derived by the type-driven default (e.g. `auto:string`, `auto:seq[byte]`, `auto:scalar:int64`) |
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
#       slabCapacity=1024 [default], maxPayloadBytes=64 [auto:scalar:int64],
#       freeListShards=4 [default]
#       — idle RAM: ring≈6.0 KB, slab≈92.0 KB, total≈98.0 KB
```

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
