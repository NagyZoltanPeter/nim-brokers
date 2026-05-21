# CBOR Refactoring — Architecture & Implementation Plan

Status: **DRAFT / proposal** — not yet approved for implementation.
Scope: the Broker FFI API surface only. Core broker macros
(`EventBroker`, `RequestBroker`, `MultiRequestBroker` and their `mt`
variants) are **not** touched.

> Filename note: requested as `CBOR_Refactoring.dm`; written as `.md`
> (Markdown) — assumed a typo.

---

## 1. Goals & non-goals

### Goals (this round)

1. **Retire the native C-ABI codegen entirely.** CBOR becomes the single
   FFI transport. This collapses five per-language native type-mapping
   codegens into one serialization contract and closes the native-vs-CBOR
   type-mapping gap permanently (object-as-param, `array[N,Object]`,
   `array[N,string]`, nested objects, `Option[T]` edge cases).
2. **Simplify the CBOR buffering / dispatch mechanism** (the "buffer
   courier" optimization) — move CBOR decode/encode and the adapter onto
   the processing thread, eliminate the typed marshal/unmarshal round-trip
   and the momentary chronos loop on foreign threads.

### Non-goals (explicitly deferred)

- **`FASTAPI` annotation** — a low-overhead positional-CBOR encoding for
  scalar-only brokers. **Deferred to a follow-up round** — design is
  retained below in §5 for reference but is *out of scope for the first
  round*. The first round delivers Parts A and C only.
- A **CBOR-derived typed C functional interface** (`<lib>.h` + `<lib>.c`
  that hide CBOR behind per-request C functions). Deferred. **Consequence:
  pure-C consumers temporarily have only the raw 11-function ABI** — see
  §4.5.
- Changing the event (`_subscribe` callback) delivery path. Events keep
  their current delivery-thread mechanism. Only the request (`_call`) path
  is reworked here.
- Changing core (non-FFI) broker behavior.

### Success criteria (this round)

- One FFI codegen path (CBOR). `mfNative` and all native codegen modules
  deleted.
- Request path: foreign threads no longer need a chronos dispatcher.
- All CBOR parity tests still green; new stress / shutdown-race tests green
  under ASAN and valgrind, under both `--mm:orc` and `--mm:refc`.

---

## 2. Current state (baseline)

### 2.1 Two coexisting FFI strategies

`brokers/internal/api_ffi_mode.nim` defines `BrokerFfiMode = {mfNative,
mfCbor}`. Selection: `-d:BrokerFfiApiNative` → `mfNative`,
`-d:BrokerFfiApiCBOR` → `mfCbor`, else default `mfCbor`. The two strategies
are **module-level separate** — not `when`-branches inside one path.

| Concern | Native (`mfNative`) | CBOR (`mfCbor`) |
|---------|---------------------|-----------------|
| C ABI | one C function per request, per-type structs | fixed 11-function ABI, payload = CBOR |
| Request codegen | `api_request_broker.nim` (~125 KB) | `api_request_broker_cbor.nim` (~16 KB) |
| Event codegen | `api_event_broker.nim` (~80 KB) | `api_event_broker_cbor.nim` (~3 KB) |
| C / C++ header | `api_codegen_c.nim`, `api_codegen_cpp.nim` | `api_codegen_cbor_h.nim`, `api_codegen_cbor_hpp.nim` |
| Python / Rust / Go | `api_codegen_python/rust/go.nim` | `api_codegen_cbor_py/rust/go.nim` |
| Nim→C type map | `api_codegen_nim.nim` (`toCFieldType`) | n/a (CBOR codec) |
| Type-mapping completeness | partial — `// TODO` stubs | full parity matrix |

> **Caution — shared code.** `api_event_broker_cbor.nim` is only ~3 KB,
> which strongly implies it leans on shared parsing/registry helpers that
> currently live inside the large `api_event_broker.nim`. Likewise
> `api_request_broker_cbor.nim` vs `api_request_broker.nim`. Retirement is
> therefore **not** "delete the big files" — it is "extract the shared
> portion, then delete the native-only portion." This is the single
> highest-risk task in the plan. See §4.2.

### 2.2 Current CBOR request path (`_call`)

Traced precisely (see `doc/` discussion history). For one cross-thread
request from a foreign thread:

1. C++ wrapper encodes typed args → CBOR **map** (keyed by field name) into
   a buffer obtained from `<lib>_allocBuffer` (Nim shared heap).
2. `<lib>_call(ctx, name, reqBuf, len, &respBuf, &respLen)` — runs on the
   **foreign thread**. `api_library.nim` ~line 1979–2030.
3. `_call` `copyMem`s `reqBuf` into a GC `seq[byte]` (`nimReq`), frees
   `reqBuf` (`deallocShared`), then `waitFor <lib>CborDispatch(...)` —
   spinning a **momentary chronos loop on the foreign thread**.
4. The adapter (`api_request_broker_cbor.nim` ~line 259–267) `cborDecode`s
   `nimReq` → typed Nim args **on the foreign thread**, then
   `await <Type>.request(ctx, args...)`.
5. `<Type>.request` is the MT broker. Provider was registered on the
   **processing thread**, so this is cross-thread: typed args are
   **marshalled** into an MT slab cell (`mt_request_broker.nim` ~850),
   crossing #1.
6. Processing thread unmarshals → typed args, runs the provider →
   `Result[T]`, marshals it into a response slot, crossing #2.
7. Foreign thread unmarshals `Result[T]` (`mt_request_broker.nim`
   ~875–879), `cborEncodeResultEnvelope` → `seq[byte]`, copies into a
   fresh `allocShared0` `respBuf`.
8. `_call` returns; C++ decodes CBOR → typed result; `~NimBuffer` calls
   `<lib>_freeBuffer`.

**Cost for one simple call:** 2 shared-heap allocations, ~6 copy/marshal
passes, 4 serialize/deserialize transforms, 2 thread crossings, plus a
chronos loop spun on the foreign thread.

The redundancy: args are already serialized (CBOR), then **re-marshalled**
into the MT slab format. Double serialization.

---

## 3. Target architecture

```
                         ONE FFI strategy: CBOR
   ┌──────────────────────────────────────────────────────────────┐
   │  C++ / Python / Rust / Go wrappers  (typed, generated)         │
   │  pure C: raw 11-function ABI only (typed C wrapper = deferred)  │
   └──────────────────────────────────────────────────────────────┘
                              │  fixed 11-function CBOR ABI
                              ▼
   ┌──────────────────────────────────────────────────────────────┐
   │  api_library.nim  —  _call = buffer courier                    │
   │     foreign thread: enqueue blob + block; no chronos, no decode │
   └──────────────────────────────────────────────────────────────┘
                              │  Channel[CborCallMsg] (raw buffer ptr)
                              ▼
   ┌──────────────────────────────────────────────────────────────┐
   │  processing thread  —  decode → provider → encode              │
   │     CBOR map payload (all brokers)                             │
   └──────────────────────────────────────────────────────────────┘
```

This round delivers two workstreams — **Part A** (retire native) and
**Part C** (buffer courier) — sequenced in §8. **Part B (`FASTAPI`) is
deferred**; its design is kept in §5 for the follow-up round.

---

## 4. Part A — Retire native C-ABI codegen

### 4.1 Files to DELETE outright

These are native-only and have a CBOR counterpart; delete after confirming
no shared symbols are imported elsewhere:

| Delete | CBOR counterpart that stays |
|--------|-----------------------------|
| `brokers/internal/api_codegen_c.nim` | `api_codegen_cbor_h.nim` |
| `brokers/internal/api_codegen_cpp.nim` | `api_codegen_cbor_hpp.nim` |
| `brokers/internal/api_codegen_python.nim` | `api_codegen_cbor_py.nim` |
| `brokers/internal/api_codegen_rust.nim` | `api_codegen_cbor_rust.nim` |
| `brokers/internal/api_codegen_go.nim` | `api_codegen_cbor_go.nim` |
| `brokers/internal/api_codegen_nim.nim` (`toCFieldType`) | n/a — **VERIFY** no CBOR module imports `toCFieldType` first |

### 4.2 Files to SPLIT (extract shared, delete native) — highest risk

- `brokers/internal/api_request_broker.nim` (~125 KB)
- `brokers/internal/api_event_broker.nim` (~80 KB)

Procedure (do **not** free-hand this):

1. Build a symbol-use map: for every `proc`/`template`/`macro` in these two
   files, find references from the CBOR modules
   (`api_request_broker_cbor.nim`, `api_event_broker_cbor.nim`,
   `api_codegen_cbor_*.nim`, `api_library.nim`). Use `gitnexus_impact`
   per symbol.
2. Symbols referenced by CBOR code → move to a new shared module
   `brokers/internal/api_broker_shared.nim` (parsing, registry glue,
   signature extraction, sanitization).
3. Symbols referenced only by the deleted native codegen → delete.
4. Re-point imports.
5. Compile-fence: a CBOR-only build must not transitively pull in any
   deleted symbol.

> Memory/thread note: this step moves code, it does not change runtime
> behavior. Risk is *compile-time breakage*, not memory safety — but a
> careless extraction that drags a native-only `threadvar` or global into
> the shared module would change runtime state. **Review every moved
> top-level `var`/`{.threadvar.}` individually.**

### 4.3 `api_ffi_mode.nim` simplification

- Remove the `mfNative` enum value. `BrokerFfiMode` collapses to a single
  case — keep the enum (one value) or remove it and the `ffiMode:` field.
  Recommended: keep a one-value enum short-term to minimize churn, remove
  in a follow-up.
- `-d:BrokerFfiApiNative` becomes a **hard compile error** with a message
  pointing here ("native FFI retired — see doc/CBOR_Refactoring.md").
  Do not silently ignore it; a silent ignore would let a stale build
  script produce the wrong artifact.
- `resolveFfiMode` degrades to a consistency check / no-op.

### 4.4 `api_library.nim` & `api_common.nim`

- `api_library.nim`: delete the `mfNative` branch of surface emission.
- `api_common.nim` (re-export hub): drop native codegen re-exports; add the
  new `api_broker_shared.nim`.

### 4.5 Consumers, examples, build tasks, CI

| Item | Action |
|------|--------|
| `examples/ffiapi/example/main.c` (native pure-C) | **Replace** with a minimal raw-ABI smoke test, or delete. Typed C wrapper is deferred (§1 non-goals). |
| `examples/ffiapi/cpp_example`, `python_example`, `rust_example`, `go_example` | Keep — already build the CBOR mode. Drop native build variants. |
| `examples/torpedo/*` | Same — keep CBOR, drop native. |
| `brokers.nimble` tasks | Delete `runFfiExampleC/Cpp/Py/Rust/Go` (native), native `testFfiApiCpp`, native `runTypeMapTestLib*`. Keep all `*Cbor*` tasks and core `test`. |
| GitHub Actions CI | Delete native jobs; keep `testApiCbor`, `runFfiExampleCborCpp`, `runTypeMapTestLibCbor*`, core `test`. |
| `doc/TYPESUPPORT.md`, `doc/TYPE_SURFACE.md`, `doc/FFI_API.md`, `AGENTS.md` | Rewrite: one FFI mode; drop native matrix; document `FASTAPI`. |

**Stated consequence:** until the deferred typed C interface lands, a pure-C
integrator must hand-encode CBOR against the 11-function ABI. C++, Python,
Rust, Go are unaffected (they have CBOR wrappers). This is an accepted,
documented temporary regression.

### 4.6 Tests

- `test/typemappingtestlib/` — drop the native build; it becomes a
  CBOR-only parity harness. The native-vs-CBOR gating in
  `typemappingtestlib.nim` (the `when defined(BrokerFfiApiCBOR)` blocks)
  becomes unconditional — every broker is always present.
- `test_api_request_broker.nim`, `test_api_event_broker.nim`,
  `test_api_library_init.nim` — **VERIFY** which are mode-agnostic; keep
  those, drop native-only assertions.

---

## 5. Part B — `FASTAPI` annotation  *(DEFERRED — follow-up round)*

> **Status: out of scope for the first round.** Parts A and C ship first.
> This section is the retained design for the follow-up round — it is not
> to be implemented now. `FASTAPI` is a *pure optimization*: omitting it
> changes nothing about correctness, type coverage, or the ABI — every
> broker simply uses the normal CBOR map path. It is safe to defer.
>
> Note on eligibility (refined since the draft): FASTAPI accepts only
> **fixed-width** scalars — bare `int`/`uint` are rejected (platform-width,
> not wire-stable; require `int64`/`int32`). `char` is a v2 candidate, not
> in the v1 scalar set. See §5.4.

### 5.1 Problem & the "through CBOR" requirement

A scalar-only broker (e.g. `add(a: int32, b: int32) -> int32`) pays for a
CBOR **map**: field-name strings encoded on the wire, key matching on
decode, descriptor-driven generic codec, two-pass size counting.
`FASTAPI` must remove that overhead **without inventing a second ABI** —
it still goes through `_call`.

### 5.2 Design — positional CBOR array (chosen)

A `FASTAPI` broker encodes its arguments as a **CBOR definite-length
array** `[v0, v1, v2]` instead of a map `{"a":v0,"b":v1,"c":v2}`. The
result is encoded the same way (array, or bare scalar for a single field).

Why this satisfies "still achievable through CBOR call":

- The payload is **still valid CBOR** — `_call`, `_getSchema`, the CDDL
  emission and any generic CBOR tooling keep working. It is a different
  CBOR *shape*, not a different format.
- No field-name strings on the wire → smaller payload, no string
  hashing/comparison on decode.
- The codegen knows the exact arity and types at compile time, so it emits
  **straight-line positional encode/decode** — no descriptor loop, no
  key dispatch.
- The maximum CBOR size of N scalars has a **static upper bound**, so the
  encoder is **single-pass** (no `CountingSink` pre-pass — allocate the
  bound, encode, done).
- CBOR integers are defined big-endian on the wire, so a positional array
  is **portable across platforms** with zero extra work.

### 5.3 Rejected alternative — raw packed POD blob

Tunneling a `#[repr(C)]`/packed struct memcpy through `reqBuf` would be
marginally faster (memcpy decode) but is **rejected**:

- Breaks `_getSchema` / CDDL / generic introspection — the blob is opaque,
  not self-describing.
- Endianness and struct-padding portability hazard across macOS / Linux /
  Windows and across architectures.
- Two payload formats on one ABI invites a class of "decoded with the
  wrong codec" bugs.

`FASTAPI` v1 = positional CBOR array. The raw-blob idea is recorded here
only as explicitly considered and declined.

### 5.4 Eligibility (compile-time enforced)

A broker may be annotated `FASTAPI` **iff** every parameter type **and**
every result field type is a trivial scalar: `bool`, `int8/16/32/64`,
`uint8/16/32/64`, `byte`, `float32/64`. Not allowed in v1: `string`,
`seq[...]`, `array[...]`, `object`, `enum`, `distinct`. The macro
**errors at compile time** with a precise message if an ineligible type is
used. (Enum / distinct-over-scalar are a possible v2 relaxation.)

### 5.5 Annotation syntax

Consistent with existing `RequestBroker(sync)` / `RequestBroker(mt)` /
`RequestBroker(API)` tokens:

```nim
RequestBroker(API, fast):
  type AddRequest = object
    sum*: int32
  proc signature*(a: int32, b: int32): Future[Result[AddRequest, string]] {.async.}
```

`fast` is parsed as an additional mode token.

### 5.6 Code-change locations

| Location | Change |
|----------|--------|
| `RequestBroker` macro entry + `brokers/internal/helper/broker_utils.nim` | Parse the `fast` token; thread a `fastApi: bool` flag through codegen. |
| `api_request_broker_cbor.nim` | Per-request adapter: when `fastApi`, emit positional-array decode (read array header, N positional scalars) instead of map decode. |
| `api_cbor_codec.nim` | Add positional-array encode/decode primitives + a static-size estimator for scalar tuples. |
| `api_codegen_cbor_hpp / py / rust / go.nim` | `FASTAPI` methods call the positional encoder/decoder; single-pass sizing. |
| `api_codegen_cbor_cddl.nim` | Emit array-typed schema for `FASTAPI` brokers. |
| Eligibility check | New compile-time validator; errors on non-scalar param/field. |

### 5.7 Memory & thread safety (Part B)

- Scalars only — no pointers, no heap beyond the request/response buffer
  itself, no ownership subtleties. The buffer follows the same
  shared-heap rules as any CBOR call.
- Single-pass encoding removes one traversal; it does **not** change
  ownership.
- `FASTAPI` is orthogonal to threading — it composes with the Part C
  courier path unchanged.
- v1 still performs the two shared-heap allocations (`reqBuf`, `respBuf`).
  A zero-allocation request (stack/borrowed buffer) would require changing
  the `_call` ownership contract (currently `_call` always frees
  `reqBuf`); that is a **documented future option**, not v1.

---

## 6. Part C — Simplify CBOR buffering (the buffer courier)

### 6.1 The change

Move the entire `<Type>CborAdapter` execution — CBOR decode, the
`.request` call, CBOR encode — onto the **processing thread**. The foreign
`_call` thread becomes a pure courier: hand a buffer pointer to the
processing thread, block on a response signal, read the response pointer.

Because the provider lives on the processing thread, the relocated
`.request` call is now **same-thread** → the MT broker takes its direct
dispatch path and the typed slab/slot marshalling is simply never
exercised for FFI calls. The typed MT path stays **fully intact for
genuine nim-to-nim cross-thread `.request` calls** — this change is
additive and FFI-only.

### 6.2 Optimized sequence

```
 [foreign / _call thread]                  [processing thread]
   reqBuf (shared heap)
     │ send {apiNameId, reqBuf ptr, len, respSlot}   ── ownership transfers
     │ fire signal ; block on respSlot
 ════╪═══ crossing #1 (opaque buffer ptr) ═══╪════
     │                                       ▼
     │                       cborDecode(reqBuf) → typed args
     │                       deallocShared(reqBuf)
     │                       await Foo.request(ctx,args)  — SAME-THREAD
     │                       provider → Result[T]
     │                       cborEncodeResultEnvelope → respBuf (shared)
     │                       write respBuf into respSlot
 ════╪═══ crossing #2 (opaque buffer ptr) ═══╪════
     ▼ unblock ; read respSlot.respBuf
   _call returns respBuf to caller  (caller frees via _freeBuffer)
```

Eliminated vs. today: the `reqBuf → nimReq` copy + its `seq` alloc; the
typed-arg marshal/unmarshal; the typed-`Result` marshal/unmarshal; the
momentary chronos loop on the foreign thread.

### 6.3 Code-change locations

| Location | Change |
|----------|--------|
| `api_library.nim` `_call` (~1979–2030) | Replace `waitFor <lib>CborDispatch` with: transfer `reqBuf` ownership, enqueue `CborCallMsg`, fire signal, block on response slot, return `respBuf`. No decode, no chronos on this thread. |
| `api_library.nim` `<lib>CborDispatch` (~1453–1475) | Relocate: invoked from the new processing-thread handler, not the `_call` thread. |
| New: `CborCallMsg` channel + handler | `Channel[CborCallMsg]` foreign→processing. **Reuse `mt_broker_common.nim`** — register a poller drained by the existing `brokerDispatchLoop` (`getOrInitBrokerSignal` / `registerBrokerPoller` / `fireBrokerSignal`). Minimal new infrastructure. |
| Response slot | A dedicated FFI response-slot pool (or reuse the `ResponseSlotPool` pattern, `mt_request_broker.nim` ~850–879), carrying `(respBuf ptr, len)` instead of a marshalled typed `Result`. |
| `api_request_broker_cbor.nim` adapter (~259–267) | Body unchanged; now runs on the processing thread. |
| `api_library.nim` `_shutdown` | **Drain the courier channel; fail every in-flight / queued `_call` with an error envelope.** See §6.4. |

### 6.4 Memory & thread safety (Part C) — the critical section

This is the part of the whole plan that most needs scrutiny.

1. **Buffer ownership across the crossing.** `reqBuf` is `allocShared0`
   (global shared heap, **not** GC). Passing the raw pointer to the
   processing thread and transferring ownership is sound under both
   `--mm:orc` and `--mm:refc` — no GC object crosses a thread. The
   processing thread becomes the sole owner and frees it after decode.
   Exactly one free. `respBuf` symmetric: allocated on the processing
   thread, ownership returns to the `_call` thread, freed by
   `_freeBuffer`. **Invariant: every buffer is freed by exactly one
   thread, with the allocator that allocated it.**
2. **No GC object crosses a thread.** Decode/encode produce GC `seq`s and
   typed objects, but those stay thread-local to the processing thread.
   The crossing carries only: scalars + a shared-heap pointer.
3. **Foreign thread no longer needs chronos.** It uses `Channel.send` +
   `ThreadSignalPtr` wait only. Removes a real fragility (provisioning a
   chronos dispatcher on an unpredictable foreign thread). **VERIFY**
   `Channel.send` of `CborCallMsg` does not itself allocate GC memory on
   the foreign thread — keep `apiName` as an interned integer id or a
   fixed-size buffer, not a Nim `string`, so the foreign thread can stay
   GC-free on the hot path. If that proves infeasible, keep
   `ensureForeignThreadGc()` and document why.
4. **Shutdown race — the top risk.** If `_shutdown` runs while a `_call`
   is queued or in flight: the processing thread must, on teardown, drain
   the channel and write an error envelope into each pending response slot
   and signal it, so every blocked `_call` returns a clean error instead
   of deadlocking or reading freed memory. Define and test the ordering:
   stop accepting new `CborCallMsg` → drain queue with errors → join
   processing thread → free pools. **No `_call` may block forever; no
   `_call` may touch a freed slot.**
5. **Concurrent `_call`s from many foreign threads.** Each call owns a
   distinct response slot (slot pool indexed per call). The channel is
   MPSC (many foreign producers, one processing consumer). `_call` is
   synchronous, so backpressure is natural — a bounded channel is
   acceptable.
6. **Processing-thread liveness.** The poller is drained by the existing
   `brokerDispatchLoop`; confirm that loop is running for the whole
   lifetime between `createContext` readiness and `_shutdown`.

---

## 7. Test plan

### 7.1 Existing (must stay green)

- `nimble test` (core brokers — mode-agnostic).
- `nimble testApiCbor`, `runFfiExampleCborCpp`, `runTypeMapTestLibCborPy`,
  `runTypeMapTestLibCborCpp`, `runFfiExampleCborRust/Go`,
  `runTypeMapTestLibCborRust/Go` — the full CBOR parity matrix
  (currently 119/119 C++).

### 7.2 New — courier path: stress & multithread

- **MT hammer:** K foreign threads each issuing M `_call`s concurrently;
  assert every response is correct (no cross-talk between slots), zero
  leaks. Run under ASAN (clang) and valgrind/memcheck.
- **Shutdown race:** issue `_call`s while concurrently calling `_shutdown`;
  assert every `_call` returns either a valid result or a clean error —
  never a hang, never a crash, never a UAF. This is the §6.4(4) test and
  is mandatory before merge.
- **Foreign-thread churn:** spawn/join foreign threads repeatedly, each
  doing a few `_call`s — verify no per-thread resource leak now that the
  chronos dispatcher is gone.
- **Buffer-lifetime:** assert the request buffer is freed exactly once and
  the response buffer is freed exactly once (instrument
  `allocShared`/`deallocShared` counts in a debug build).
- **e2e:** extend the torpedo example (it already exercises a realistic
  orchestrator) to run under the new courier path on all wrappers.

### 7.3 Microbenchmark (decision evidence)

A small bench harness: a representative request broker measured as (a)
normal map-encoded CBOR after the courier optimization, and (b) — captured
**before** Part A deletes it — native. Also measure the raw async-dispatch
floor. Report per-call latency. This quantifies the courier win and
records the native baseline before it is removed (the baseline is also the
reference point for evaluating the deferred `FASTAPI` work later).

---

## 8. Sequencing & effort

Recommended order — each phase independently shippable and testable.
**First round = Phases 0–2.** Part B (`FASTAPI`) is deferred to a later
round and is not scheduled here.

| Phase | Work | Why this order | Effort | Risk |
|-------|------|----------------|--------|------|
| 0 | Microbenchmark harness; capture native baseline | Must measure native before deleting it | 0.5–1 d | low |
| 1 | **Part C** — buffer courier | Biggest perf win; isolated to CBOR code; native still present as a cross-check reference | 3–5 d | **med** (shutdown race) |
| 2 | **Part A** — retire native | Collapses to one FFI strategy; the shared-code extraction is the hard part | 3–5 d | **med-high** (shared-code split) |
| — | ~~Part B — `FASTAPI`~~ | **Deferred — follow-up round** (see §5, §10) | 3–4 d | low-med |

First-round total ≈ **1.5–2 weeks** including the new test suites.

Rationale for Part C before Part A: Part C is the highest-value change and
benefits from native mode still existing as a behavioral reference while
the courier path is validated. Part A is mechanical but risky in the
shared-code extraction; doing it second means a smaller, proven CBOR
surface to carve against.

---

## 9. Risk register

| Risk | Severity | Mitigation |
|------|----------|------------|
| Shutdown race deadlocks/UAFs a blocked `_call` | **high** | §6.4(4) explicit teardown ordering + mandatory shutdown-race stress test under ASAN/valgrind before merge |
| Shared-code extraction from the 125 KB / 80 KB files breaks the CBOR build or moves a stateful global | **high** | Per-symbol `gitnexus_impact`; review every moved top-level `var`/`threadvar`; compile-fence a CBOR-only build |
| Foreign thread still needs GC for `Channel.send` | med | Keep `apiName` as an interned id / fixed buffer; if infeasible, retain `ensureForeignThreadGc()` and document |
| Pure-C consumers lose typed ergonomics | med (accepted) | Documented in §1/§4.5; raw-ABI smoke test kept; typed C interface is a tracked deferred item |
| `--mm:refc` vs `--mm:orc` divergence on the courier path | med | Buffers are shared-heap (not GC) → expected identical; still run the full matrix under both |
| CI gap after deleting native jobs | low | Audit the workflow; ensure every retained behavior still has a job |

(`FASTAPI`-specific risks are out of scope for this round — see §5/§10.)

---

## 10. Deferred / follow-up

- **`FASTAPI` annotation (Part B)** — the whole feature is deferred to a
  follow-up round. Design is retained in §5. It is a pure optimization for
  scalar-only brokers (positional CBOR array instead of a map) and has no
  bearing on correctness or type coverage, so deferring it is safe. Pick
  it up after Parts A and C have shipped and stabilized.
- **CBOR-derived typed C functional interface** — generated `<lib>.h` +
  `<lib>.c` that hide CBOR behind per-request C functions (needs a small C
  CBOR codec — TinyCBOR/QCBOR, or a generated dependency-free subset
  codec). Restores typed pure-C ergonomics.
- **`FASTAPI` zero-allocation request** — borrowed/stack request buffer,
  requires changing the `_call` ownership contract. (Sub-item of the
  deferred `FASTAPI` work.)
- **`FASTAPI` v2** — allow enum, `char`, and distinct-over-scalar
  parameters. (Sub-item of the deferred `FASTAPI` work.)
- Collapsing the one-value `BrokerFfiMode` enum and removing the
  `ffiMode:` field entirely.
- Applying the courier model to the event delivery path.
