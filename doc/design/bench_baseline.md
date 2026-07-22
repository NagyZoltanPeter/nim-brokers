# FFI Request Path — Phase 0 Baseline

Status: captured baseline. Companion to `doc/CBOR_Refactoring.md` (§7.3,
Phase 0). Recorded **before** Part C (buffer courier) and **before**
Part A (native retirement) so the courier rework can be measured against
it and the native numbers survive the deletion as a reference.

## Environment

| | |
|---|---|
| Machine | Apple M4, 10 cores |
| OS | macOS 15.7.3 |
| Compiler | AppleClang 17.0.0; Nim 2.2.4 |
| Build | `-d:release`, `--mm:orc`, `--threads:on` |
| Date | 2026-05-19 |

## Harness

`test/ffibench/` — `benchlib.nim` (two `RequestBroker(API)` brokers,
built as native and CBOR shared libraries), `bench_driver.cpp` (one
source, compiled against both generated wrappers via CMake),
`bench_inproc.nim` (in-process floor).

- **add_scalar** — `add(int32, int32) -> int32`: the simple all-scalar
  request.
- **vec_payload** — `vec(seq[int32]) -> (length, checksum)`: variable-size
  payload. Capped at 3072 bytes — a `seq[int32]` API-broker parameter
  auto-classifies to a 4 KiB MT cell and `RequestBroker(API)` accepts no
  `maxPayloadBytes` override (see Caveats).
- **inproc** — single-thread async `RequestBroker`, no FFI, no
  serialization, no thread crossing.

Every FFI result is `isOk()`-checked in the driver; a fast-failed call
(e.g. MT cell overflow) aborts the run rather than being mistimed.
Methodology: 5000-iteration warmup; add timed over 20000 iterations,
each vec size over 5000.

## Results — ns per call

| scenario | payload | native | CBOR (baseline) | **CBOR (courier)** | CBOR speedup |
|----------|--------:|-------:|----------------:|-------------------:|-------------:|
| add_scalar | 8 B | 1,234,811 | 110,861 | **20,655** | **5.4×** |
| vec_payload | 64 B | 1,230,729 | 111,163 | 22,083 | 5.0× |
| vec_payload | 256 B | 1,232,750 | 112,015 | 22,582 | 5.0× |
| vec_payload | 512 B | 1,244,795 | 114,186 | 25,051 | 4.6× |
| vec_payload | 1024 B | 1,243,926 | 117,802 | 28,266 | 4.2× |
| vec_payload | 2048 B | 1,224,936 | 127,066 | 33,339 | 3.8× |
| vec_payload | 3072 B | 1,224,580 | 132,355 | 38,429 | 3.4× |
| **inproc floor** | 8 B | **249.9** | — | — | — |

The "CBOR (courier)" column was captured on the same hardware/build
after Part C Phase 1b (the buffer-courier rework): `<lib>_call` no
longer drives a chronos `waitFor` poll on the foreign thread; it hands
the raw request buffer to the processing thread and blocks on a
`Lock`+`Cond` response slot.

## Analysis

### 1. Native `_call` is a flat ~1.23 ms — poll-bound

Native FFI request latency is **~1.23 ms regardless of payload size**.
Serialization cost is completely invisible against it (the 64 B and
3072 B numbers differ by noise). A flat ~1 ms fixed cost is the signature
of the MT request broker's **blocking-await `sleep(1)` busy-poll** — the
foreign `_call` thread waits on the response slot one ~1 ms quantum at a
time. Against the 250 ns in-process floor this is **~4940×**.

### 2. CBOR `_call` is ~111–132 µs — ~11× faster than native

The CBOR path drives a momentary chronos loop (`waitFor`) on the foreign
thread rather than the `sleep(1)` blocking poll, so its fixed cost is
~111 µs, not ~1 ms — already an order of magnitude better than native on
the *same* MT cross-thread machinery. Against the floor: **~444×**.

### 3. CBOR shows real serialization scaling; native cannot

CBOR vec latency rises from 111.2 µs (64 B) to 132.4 µs (3072 B) —
≈ 7 µs/KiB of visible encode+decode cost. Native's serialization cost is
real too but buried under the 1.23 ms poll, so it cannot be observed
here.

### Takeaways for the refactoring

- The headline cost on the FFI request path is **not** CBOR
  serialization (~7 µs/KiB) — it is **cross-thread handoff latency**:
  ~1.23 ms (native, `sleep(1)` poll) or ~111 µs (CBOR, chronos poll).
- **Part C (buffer courier)** must replace any poll with a direct
  signal-based wake. Target: collapse the ~111 µs CBOR fixed cost toward
  the floor + one thread wakeup (low single-digit µs).
- This baseline already justifies retiring native independently of
  performance: native is 11× *slower* on this path, not faster.

## Caveats

- **In-proc floor is single-thread.** It is the chronos-dispatch-only
  floor and omits the cross-thread channel hop the FFI path pays. The
  true MT cross-thread floor sits above 250 ns; a dedicated MT
  cross-thread floor bench is a follow-up refinement.
- **vec payload capped at 3072 B.** A `seq[int32]` API-broker parameter
  is classifier-sized to a 4 KiB MT cell, and `RequestBroker(API)` rejects
  `maxPayloadBytes` kwargs — API brokers currently expose no MT-cell
  tuning knob. Larger payloads would need the `seq[byte]` 64 KiB
  classification (non-uniform native/CBOR C++ surface) or a new
  API-broker config mechanism.
- Single machine, single run. Numbers are indicative, not statistical;
  re-run on the same machine for the Part C before/after comparison.

## Post-courier — Part C Phase 1b result

**3.4×–5.4× faster than the CBOR baseline across the whole curve.**
`add_scalar` collapsed from 110.9 µs to **20.7 µs**; the constant CBOR
overhead — the chronos `waitFor` poll on the foreign thread — is gone.
The remaining ~20 µs floor is the cross-thread handoff itself: channel
send + dispatch-signal fire + `brokerDispatchLoop` wake + handler
`asyncSpawn` + `Cond` signal/wake. Serialization scaling is now clearly
visible (~5 µs/KiB across 64 B → 3072 B), no longer hidden under the
poll.

Regression: `testApiCbor` 26/26 OK under `--mm:refc` (incl. the full
parity matrix — primitives, options, byte-strings, tuples, object-param,
distinct-over-seq); `runFfiExampleCborCpp` (the canonical `mylib` C++
example with events + requests) clean end-to-end. No regressions.

Next refinements (potential Phase 2): drop `ensureForeignThreadGc()` if
the foreign-thread path can be made provably GC-free; explore whether
the `Cond`-based slot handoff can collapse further toward a thread-wakeup
floor.

## Re-measure after Part A

Part A retires native codegen, so the **native** column is frozen here
as the historical reference. The CBOR (courier) column is the live
baseline going forward.

## Event dispatch — Part D-6 (CBOR mode only)

Companion to `doc/CBOR_Round2_PartD_EventCourier.md`. Captures the per-emit
cost of the three-lane FFI event-dispatch design (atomic-counter fast path
+ event-courier ring + delivery-thread fan-out + dropAllListeners hook).

### Environment

| | |
|---|---|
| Machine | Apple M4, 10 cores |
| OS | macOS 15.7.3 |
| Compiler | AppleClang 17.0.0; Nim 2.2.4 |
| Build | `-d:release`, `--mm:orc`, `--threads:on` |
| Date | 2026-05-21 |

### Harness

`test/ffibench/bench_event_driver.cpp` (release CBOR build of `benchlib`
with `PingEvent` declared). For each of the four scenarios below:

1. fresh `<lib>_createContext` per scenario
2. set up the audience (foreign callbacks via `onPingEvent` and/or
   same-thread Nim listeners via `installSameThreadNimListenersRequest`)
3. issue `triggerEmitRequest(N=20000)` from the foreign caller thread —
   the provider then loops over 20K `PingEvent.emit(...)` calls on the
   processing thread
4. spin (with `usleep(50)` between probes) until every audience reports
   `>= N` deliveries
5. `ns_per_emit = (t_after_drain - t_before_emit_request) / N`
6. report median over 3 reps

The wall-clock window therefore captures **both** the emit-side cost
(atomic check / encode / courier enqueue) **and** the delivery-side cost
(courier dequeue + fan-out + free), and includes any cross-thread
batching the delivery thread does internally.

### Numbers

| # | Scenario | Audience | ns/emit | Delta vs (a) | Notes |
|---|---|---|---:|---:|---|
| a | no_foreign_no_nim | 0 | **615** | — | atomic-counter fast path; handler does `load(moAcquire)` → returns |
| b | one_foreign | 1 foreign cb | **976** | +361 | full courier path: 1 encode, 1 enqueue, 1 signal, 1 fanout |
| c | many_foreign | 8 foreign cbs | **895** | +280 | encode-once-on-emit-thread amortizes across 8 callbacks; (c) ≤ (b) confirms the delivery thread batches multiple events per signal-wake, so per-emit overhead does not grow linearly with fan-out width |
| d | nim_only_same_thread | 4 Nim listeners | **1170** | +555 | Lane 1 cost: 4 × direct `asyncSpawn` per emit; no CBOR involvement, no courier touch |

### Interpretation

- **(a) → (b) = +361 ns**: the courier's per-emit overhead when foreign
  subscribers are actually present. CBOR encode of a single `int64`
  payload (`seqNo`), one `allocShared0`, one ring lock-and-memcpy, one
  signal fire, one ring lock-and-memcpy on the delivery thread, one
  callback dispatch, one `deallocShared`. Dominated by the two ring
  lock acquisitions and the cross-thread signal.

- **(a) is the 90 % production case** (no foreign subscribers for a
  given emit). The atomic load is **the only cost above MT EventBroker
  dispatch**. 615 ns is dominated by MT EventBroker bookkeeping —
  Nim's `asyncSpawn` of the (empty-fanout) handler closure dominates,
  not anything Part D added.

- **(b) → (c) ≈ -80 ns**: per-callback marginal cost is essentially
  zero (negative within noise) because the encode happens once per
  emit and the delivery-thread fan-out loop is tight (one atomic
  increment per callback in the bench harness). A real consumer with
  heavier callbacks shifts this delta proportional to the callback's
  own cost.

- **(d) costs more than (b)/(c)** because the same-thread Nim path does
  `K` independent `asyncSpawn`s per emit (one chronos future allocation
  per listener), where the foreign-fanout path packs the work behind a
  single courier message.

### Reproducing

```bash
nimble runFfiBenchEvent
```

(Equivalent: `nim c -d:release -d:BrokerFfiApi --threads:on
--app:lib --path:. --outdir:test/ffibench/build --mm:orc
--nimMainPrefix:benchlib test/ffibench/benchlib.nim` then `cmake -S
test/ffibench -B test/ffibench/cmake-build -DCMAKE_BUILD_TYPE=Release`
then `cmake --build test/ffibench/cmake-build --target
bench_event_driver` then `test/ffibench/build/bench_event_driver`.)

## FFI perftest from C++ vs Nim-direct perftest

The closing comparison of the Round-2 retirement: same workload shape
(`5 threads × 500 ops × 512 B payload`) driven once from Nim
(`nimble perftest`, broker-level only) and once from C++ over the FFI
boundary (`nimble perftestFfi`, `test/ffibench/perf_driver.cpp`). The
two numbers quote the cost of crossing the FFI boundary on a workload
that is otherwise identical.

### Environment

| | |
|---|---|
| Machine | Apple M4, 10 cores |
| OS | macOS 15.7.3 |
| Compiler | AppleClang 17.0.0; Nim 2.2.10 |
| Build | `-d:release`, `--mm:{orc,refc}`, `--threads:on` |
| Date | 2026-05-21 |

### Request path — `5 × 500 × 512 B` cross-thread

| Build | Nim-direct (`req/s`) | FFI from C++ (`req/s`) | Nim avg lat | FFI avg lat | FFI p99 |
|---|---:|---:|---:|---:|---:|
| orc-release  | 38.02 K  | **151.69 K** (+3.99×) | 128.5 µs | **32.5 µs** (−75 %) | 76.1 µs |
| refc-release | 38.33 K  | **149.27 K** (+3.89×) | 127.4 µs | **33.1 µs** (−74 %) | 75.3 µs |
| orc-debug    | 29.23 K  | 26.56 K (−9 %)        | 166.7 µs | 187.9 µs (+13 %)    | 498.5 µs |
| refc-debug   | 28.82 K  | 21.19 K (−26 %)       | 168.5 µs | 235.6 µs (+40 %)    | 470.6 µs |

**Why FFI release is *faster* than Nim-direct.** Counter-intuitive at
first read, but matches the design: the FFI `_call` courier rewrite
(Part C Phase 1) moved the broker `.request()` invocation onto the
processing thread. The Nim-direct cross-thread path traverses the
typed MT marshal/unmarshal slab + ring; the FFI path skips that — it
goes CBOR-encode → buffer-courier → same-thread broker dispatch →
CBOR-encode-response → response-slot wake. Fewer hops, simpler memory
operations. The trade is that the FFI path pays CBOR encoding
overhead, but for a 512 B payload that's cheap relative to the
slab/ring transit it replaces.

### Event path — `5 × 500 × 512 B`

| Build | Nim-direct (`evt/s`) | FFI from C++ (`evt/s`) | Nim avg lat | FFI avg lat | FFI p99 |
|---|---:|---:|---:|---:|---:|
| orc-release  | 629.01 K | 152.00 K (−76 %) | 687.9 µs  | **33.7 µs** (−95 %) | 61.0 µs |
| refc-release | 514.75 K | 160.89 K (−69 %) | 21.7 µs   | 34.2 µs (+58 %)     | 70.0 µs |
| orc-debug    | 90.85 K  | 31.48 K (−65 %)  | 12.369 ms | **165.1 µs** (−99 %)| 204.4 µs |
| refc-debug   | 123.94 K | 26.06 K (−79 %)  | 7.335 ms  | **192.8 µs** (−97 %)| 341.1 µs |

**Why FFI event is *slower* on throughput but often *faster* on
latency.** The FFI event path traverses more hops: C++ trigger → Nim
provider → broker emit (same-thread on processing thread) → MT broker
fan-out (same-thread direct dispatch to a per-event handler that
encodes CBOR + writes to the event courier ring) → delivery thread
drains ring → decode CBOR → invoke C++ callback. The Nim-direct
cross-thread emit is one hop: emit thread → MT broker dispatch →
listener thread chronos coroutine. So per-event throughput is lower
on the FFI side.

Latency comparison is more interesting. orc-release Nim-direct shows
688 µs average because the Nim-direct harness measures emit→listener-
spawn end-to-end including chronos scheduling latency under burst
(15 % drops in the older baseline — see § "Event dispatch — Part
D-6"). The FFI path keeps drops at 0 % and trades for stricter
latency control via the courier's bounded ring + signal. refc-release
Nim-direct shows 22 µs — the broker is back-pressuring at a lower
offered rate, so latency stays tight.

Note: latency comparison is harness-dependent. The Nim-side perftest
measures `now - evt.timestampNs` where the timestamp is stamped at
emit; the FFI side measures the same delta in `steady_clock` ns. Both
use the same underlying clock on macOS (`mach_absolute_time`) but
record from slightly different points in the dispatch chain — the
absolute numbers are comparable to ~1 µs, the trends are what matter.

### Same-thread baseline (Nim-direct only — not applicable to FFI)

| Build | Request `req/s` | Event `evt/s` |
|---|---:|---:|
| orc-release  | 478.10 K | 33.04 K |
| refc-release | 1.20 M   | 41.77 K |

FFI has no same-thread analogue — any foreign caller is cross-thread
by construction. These numbers sit alongside as the in-process floor.

### Reproducing

```bash
nimble perftest        # Nim-direct
nimble perftestFfi     # FFI from C++
```

`MM=refc` / `MM=orc` overrides each task to a single memory manager;
the default iterates both. Debug builds run the same matrix without
`-d:release`.


## Submit scaling — one-way signal `_call` ingress (bench_ffi_submit)

nim-brokers analog of nim-ffi's `tests/bench/bench_ffi_submit.nim`
(logos-messaging/nim-ffi #97 / #101): K producer threads hammer one library
context with `benchsubmit_call` on a `SignalBroker(API)` apiName — the
slot-free, one-way enqueue onto the call-courier ring, the closest semantic
match to nim-ffi's `sendRequestToFFIThread` (pure ingress, no response
round-trip in the measured path).

### Environment

- Apple M4 (10 cores), macOS, Nim 2.2.10
- `-d:danger` (matches the nim-ffi methodology), `--threads:on`
- median of 5 iterations per thread count; fresh context per iteration
- 20 000 submits per producer thread; 4 B CBOR payload; noop handler
  (bumps an `Atomic[int]` on the processing thread)

### Harness semantics (divergences from nim-ffi)

- **Bounded ingress with backpressure.** nim-ffi's intrusive queue is
  unbounded; our courier ring is finite, so `_call` returns
  `ApiStatusAgain` (-6) when full. Producers spin-retry until accepted
  (no backoff), and retries are reported per row — a retry-dominated row
  means the "submit rate" is really the consumer drain rate. Since the
  `callRingCeiling:` knob landed, the bench registers its library with
  `callRingCeiling: 2_000_000` (= the largest documented sweep), so
  documented runs never hit `-6` and measure pure enqueue; the retry
  loop remains as a fallback for oversized custom sweeps.
- **Per-attempt buffer cost.** Ownership of the input buffer transfers
  into the library on every `_call` return path (freed by the library on
  -6/-10 too), so each retry pays `allocBuffer` + `copyMem` again. That
  is the honest foreign-caller submit path.
- **Correctness gate identical**: handler-invocation count must equal
  accepted submits exactly (no drops, no double-fires), zero hard errors.

### Numbers — default ring (64 slots), drain-bound (2026-07-20)

Measured before the ring-ceiling knob existed, i.e. with the stock
64-entry call-courier ring. These rows are **drain-bound**: acceptance
is capped by the processing thread, not by enqueue cost.

Default sweep, submit/sec (accepted) and scaling vs 1 thread:

| threads | orc | vs 1T | orc retries | refc | vs 1T | refc retries |
| ---: | ---: | :---: | ---: | ---: | :---: | ---: |
| 1 | 753 K | 1.00x | 555 K | 716 K | 1.00x | 667 K |
| 2 | 1.10 M | 1.46x | 350 K | 923 K | 1.29x | 1.00 M |
| 4 | 1.06 M | 1.41x | 377 K | 708 K | 0.99x | 1.94 M |
| 8 | 295 K | 0.39x | 752 K | 267 K | 0.37x | 3.38 M |

High-contention curve (orc), `BROKER_SUBMIT_THREADS="1,8,16,32,64,100"`:

| threads | submit/sec | vs 1T | again-retries | retries/submit |
| ---: | ---: | :---: | ---: | ---: |
| 1 | 725 K | 1.00x | 533 K | ~27 |
| 8 | 297 K | 0.41x | 703 K | ~4 |
| 16 | 188 K | 0.26x | 19.0 M | ~59 |
| 32 | 103 K | 0.14x | 110.7 M | ~173 |
| 64 | 59 K | 0.08x | 506.7 M | ~396 |
| 100 | 40 K | 0.06x | 1.24 B | ~620 |

Correctness held at every row: handler count matched accepted submits
exactly, zero hard errors, zero overruns (both memory managers).

### Interpretation

1. **The ceiling is the drain, not the enqueue.** Even one producer
   out-runs the courier consumer (~27 retries per accepted submit at
   1T): accepted throughput ≈ the processing thread's decode + dispatch
   rate (~0.7–1.1 M/s), and the ring (64 slots) is perpetually full.
2. **Anti-scaling past ~2 producers.** Peak is ~1.1 M/s at 2 threads;
   at 100 threads aggregate acceptance collapses to 0.06x of the
   1-thread rate while retries grow to ~620 per submit. Spin-retrying
   producers contend on the ring's shared head and steal cores from the
   consumer — the same single-hotspot collapse nim-ffi #101 measured
   for its single lock-free MPSC candidate (0.10x at 100 threads).
3. **Direct comparison with nim-ffi #101.** Their sharded, mutex-guarded
   16-lane ingress reached ~24 M enq/s and 11x scaling — but against an
   *unbounded* queue with no per-submit alloc. The comparable lesson is
   structural, not absolute: one shared ingress point (our courier ring)
   caps and then inverts scaling; sharding the ingress and coalescing
   wakes is what buys headroom if concurrent foreign callers matter.
4. **Retry policy is part of the picture.** The bare spin (no backoff)
   maximises pressure and makes the contention visible; a small backoff
   would raise aggregate acceptance at high K but hide the raw curve.

No scaling gate is enforced yet (`BROKER_SCALING_GATE=0` default): this
is the baseline. If the courier ingress is ever sharded per nim-ffi
#101, flip the gate on (threshold 1.5x, nim-ffi parity) as the
regression guard.

### Pure enqueue — `callRingCeiling: 2_000_000` (2026-07-20)

`registerBrokerLibrary` gained a `callRingCeiling:` key: the call ring
keeps its 64-entry base and doubling ("spill") growth, but the growth
ceiling — classically `4 × base = 256` — becomes configurable (explicit
values must be ≥ 256; `eventRingCeiling:` is the symmetric knob for the
event courier, base 256, default ceiling 1024). Sync calls stay
slot-gated; the spill headroom serves the signal lane. With the ceiling
set to the full sweep, `Again` never fires (0 retries at every row) and
the timed phase is **pure enqueue plus the amortized growth copies** as
the ring spills 64 → 2 M — the apples-to-apples shape against nim-ffi's
unbounded ingress.

Memory cost of fitting the bench: `CborCallMsg` is 280 B (256 B of it
the fixed `apiName` field), so the 2 M ceiling = **534 MiB per context
at full growth** — reached only when backlog actually demands it, and
freed at each per-iteration context destroy. The default `1,2,4,8`
sweep grows to ≤ 160 K entries ≈ 43 MiB.

Default sweep, submit/sec and scaling vs 1 thread (0 retries everywhere):

| threads | orc | vs 1T | refc | vs 1T |
| ---: | ---: | :---: | ---: | :---: |
| 1 | 1.41 M | 1.00x | 1.41 M | 1.00x |
| 2 | 1.66 M | 1.17x | 1.69 M | 1.20x |
| 4 | 1.24 M | 0.88x | 1.24 M | 0.88x |
| 8 | 262 K | 0.18x | 282 K | 0.20x |

High-contention curve (orc):

| threads | submit/sec | vs 1T |
| ---: | ---: | :---: |
| 1 | 1.35 M | 1.00x |
| 8 | 257 K | 0.19x |
| 16 | 167 K | 0.12x |
| 32 | 166 K | 0.12x |
| 64 | 173 K | 0.13x |
| 100 | 156 K | 0.12x |

An earlier variant of the knob **preallocated** the ring instead of
growing it; that variant measured 2.4–2.8 M/s at 1T with the same
~170–190 K/s contention floor. The ~45 % lower 1T rate here is the
amortized cost of the doubling growth (realloc + linearising copy under
the ring lock, ~15 doublings across a 2 M-submit iteration) — the price
of not committing 534 MiB up front.

Interpretation:

1. **Uncoupled single-thread floor is ~1.4 M enq/s grow-as-you-go**
   (~2.4–2.8 M preallocated, vs ~0.7 M drain-bound): one enqueue =
   `allocBuffer` + 4 B copy + registry lookup + 280 B msg copy under the
   ring lock + `fireBrokerSignal`, plus the amortized spill copies.
   nim-ffi's floor is 2.14 M (sharded) / 1.18 M (their Vyukov) — same
   order of magnitude despite our extra ABI + alloc work.
2. **The collapse is attributable to the ingress itself**, not to
   retry-starvation: with zero retries the curve still inverts to a
   ~155–175 K/s contention floor (0.12x) that is *flat* from 16 to 100
   threads. Structurally identical to nim-ffi's single lock-free MPSC
   (0.10x at 100T): one shared cache line (ring lock + count) plus a
   per-submit wake syscall caps aggregate throughput regardless of
   producer count.
3. **Fix shape is known.** nim-ffi #101's answer — shard the ingress
   into per-producer lanes and fire the wake only on an
   empty→non-empty edge — held 11x at 100 threads. Both techniques
   apply directly to the call-courier if concurrent foreign callers
   become a real workload.

### Reproducing

```bash
nimble benchFfiSubmit                       # orc + refc, default 1,2,4,8
BROKER_SUBMIT_THREADS="1,8,16,32,64,100" MM=orc nimble benchFfiSubmit
# knobs: BROKER_SUBMIT_PER_THREAD (20000), BROKER_SUBMIT_ITERS (5),
#        BROKER_SCALING_GATE (0)
```

## E2E throughput scaling — C++ through the dylib (bench_e2e_driver)

`nimble benchFfiE2e` — the full-foreign-boundary companion to
`benchFfiSubmit`: a real C++ driver through the generated `benchlib.hpp`
wrapper + `libbenchlib.dylib`; the clock measures **processed** throughput
(drain / callback / round-trip complete), not submit. Three lanes:

1. **signal** — one-way `_call`; drain-timed via a polled stats request;
   aggregate checksum verified.
2. **async** — `_callAsync` turnaround; clock stops at the last callback;
   every returned value verified.
3. **sync** — blocking `_call` turnaround; per-thread serial round trips.

Each lane runs in two payload families: **hash** (500 B byte payload, the
Nim handler FNV-1a-hashes it — copy-heavy) and **scalar**
(`(int64, int64, float64) -> bool` parity predicate — framing/dispatch cost
isolated from the payload copy+hash).

benchlib registers `callRingCeiling: 16384` (burst headroom, then real `-6`
which the driver retries and reports). `asyncQueueDepth` stays at the
default 64. Median of 3, fresh context per iteration, threads
`1,2,4,8,16,32,64`. Apple M4 (10 cores), `-d:release`, 2026-07-21.

### Numbers — msg/s (payload MB/s in parens at the plateau)

orc:

| threads | signal | vs 1T | async | vs 1T | sync | vs 1T |
| ---: | ---: | :---: | ---: | :---: | ---: | :---: |
| 1 | 321 K | 1.00x | 213 K | 1.00x | 41 K | 1.00x |
| 2 | 358 K | 1.11x | 211 K | 0.98x | 96 K | 2.35x |
| 4 | 330 K | 1.02x | 218 K | 1.02x | 228 K | 5.59x |
| 8 | 291 K | 0.90x | 205 K | 0.96x | 204 K | 5.01x |
| 16 | 203 K | 0.63x | 178 K | 0.83x | 204 K | 4.99x |
| 32 | 238 K | 0.74x | 156 K | 0.73x | 202 K | 4.95x |
| 64 | 232 K (116 MB/s) | 0.72x | 168 K (84 MB/s) | 0.78x | 195 K (98 MB/s) | 4.78x |

refc: signal 449 K → 191 K (0.42x at 64T), async 233 K → 100 K (0.43x),
sync 44 K → 241 K (5.45x, plateau slightly above orc). Correctness
(counts + hashes) held at every row under both memory managers; sync
never saw a single `-6` (the 64→256 slot pool absorbs 64 blocking
callers).

Scalar family (orc), msg/s and scaling vs 1 thread:

| threads | signal | vs 1T | async | vs 1T | sync | vs 1T |
| ---: | ---: | :---: | ---: | :---: | ---: | :---: |
| 1 | 1.09 M | 1.00x | 491 K | 1.00x | 44 K | 1.00x |
| 2 | 1.04 M | 0.95x | 497 K | 1.01x | 98 K | 2.20x |
| 4 | 918 K | 0.84x | 434 K | 0.88x | 468 K | 10.5x |
| 8 | 332 K | 0.30x | 332 K | 0.67x | 472 K | 10.6x |
| 16 | 246 K | 0.22x | 304 K | 0.61x | 450 K | 10.1x |
| 32 | 218 K | 0.20x | 297 K | 0.60x | 407 K | 9.18x |
| 64 | 262 K | 0.24x | 298 K | 0.60x | 433 K | 9.76x |

refc scalar: signal 1.23 M → 170 K (0.13x at 64T), async 452 K → 108 K
(0.23x), sync 46 K → 339 K (7.40x).

### Interpretation

1. **Every lane converges on the same ceiling — the processing thread.**
   ~200–240 K msg/s ≈ 100–180 MB/s of payload is the single-threaded
   CBOR-decode + hash + dispatch rate; no ingress design change moves it.
   This is the number the submit bench deliberately excluded, and for
   sustained load it, not the ingress, is the system's capacity.
2. **Signal peaks early (~360–430 K/s at 2T, ring still absorbing) then
   sheds 30 % (orc) / 50 % (refc)** as producer spin-retries at the 16 K
   ceiling steal cores from the consumer — the e2e echo of the ingress
   bench's contention collapse, much milder because the drain dominates.
3. **Async is window-bound, not ingress-bound**: with `asyncQueueDepth`
   64, producers spend their time in `Again` retries (10 M+ at 64T) and
   throughput tracks slightly below signal. Raising the window would trade
   memory (in-flight requests + response ring) for the gap to the drain
   ceiling.
4. **Sync is latency-then-ceiling**: one thread = ~25 µs round trip
   (40 K/s); concurrency hides latency perfectly up to 4 threads, then the
   provider-side ceiling takes over — and it needs no retry loop at all up
   to 64 callers thanks to the slot pool. For ≤ 64-thread foreign apps the
   blocking lane is competitive with async at far simpler call-site
   semantics.
5. **The scalar family shifts the bottleneck back toward the ingress.**
   With the 500 B copy+hash gone, per-message processing cost drops ~3x
   (scalar signal floor: 1.09 M/s at 1T vs 328 K hashed) — so the drain
   stops being the wall and the lanes diverge: the signal lane re-inherits
   the ingress contention collapse (0.20–0.30x past 8T, the submit-bench
   shape), async roughly doubles its plateau (~300 K, still window-bound),
   and **blocking sync becomes the fastest lane at concurrency**
   (~430–470 K/s plateau, 10.5x) because each round trip parks its
   producer in a `Cond` wait instead of spin-retrying against a shared
   ring — backpressure by construction. Round-trip latency at 1T is
   payload-independent (~22–25 µs both families): the handoff, not the
   payload, dominates a single call.

### Reproducing

```bash
nimble benchFfiE2e            # orc + refc; MM=orc for one manager
BROKER_E2E_THREADS="1,8,64" BROKER_E2E_PER_THREAD=20000 nimble benchFfiE2e
# knobs: BROKER_E2E_PER_THREAD (10000), BROKER_E2E_ITERS (3),
#        BROKER_E2E_PAYLOAD (500), BROKER_E2E_THREADS (1,2,4,8,16,32,64)
```
