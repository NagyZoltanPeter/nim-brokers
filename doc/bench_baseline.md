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
