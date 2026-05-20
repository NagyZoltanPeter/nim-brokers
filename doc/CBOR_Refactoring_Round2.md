# CBOR Refactoring — Round 2 Plan

Status: **DRAFT / proposal** — not yet approved for implementation.
Scope: follow-up to `doc/CBOR_Refactoring.md`. Round 1 (Parts A + C,
Phase 0 baselines) shipped on the `retire-native-cbor-optimize` branch
through commits 4f70719…16d8c7b. CBOR is now the only FFI mode and the
request `_call` path uses a buffer courier.

Round 2 picks up the items the round-1 plan explicitly deferred (§10),
**plus** the local janitorial work surfaced during the Phase 2 sweep.
`FASTAPI` (Part B) remains deferred to a later round.

---

## 1. Goals & non-goals

### Goals (this round)

1. **Extend the buffer courier to the event delivery path.** Today the
   request `_call` path goes through the courier (foreign-thread →
   processing-thread, opaque CBOR buffer, no typed marshalling); the
   event `_subscribe` callback path still rides the original
   delivery-thread mechanism, which round-trips typed payloads through
   the MT EventBroker slab before encoding to CBOR at the delivery-side
   coroutine. Round 2 makes the event path symmetric with the request
   path.
2. **Simplify the compile-flag / `ffiMode:` selection surface.** With
   only `mfCbor` left, the `BrokerFfiMode` enum, the
   `parseFfiModeLiteral` / `resolveFfiMode` machinery, and the optional
   `ffiMode:` field on `registerBrokerLibrary` are residual ceremony.
   Collapse them to a single `-d:BrokerFfiApi` switch (with
   `-d:BrokerFfiApiCBOR` kept as a back-compat alias for one release).
3. **Sweep the `USE_CBOR` ifdef arms in the C++ sources** that became
   unconditional in commit 0370821 once the CMake `option(USE_CBOR …)`
   went away.
4. **Restore typed pure-C consumer ergonomics** via the deferred
   "CBOR-derived typed C functional interface" (CBOR_Refactoring §10).

### Non-goals (explicitly deferred again)

- **`FASTAPI` annotation (Part B from round 1).** Still deferred. No
  change to the design retained in CBOR_Refactoring.md §5.
- **`FASTAPI` zero-allocation request** — sub-item of #B above.
- **`FASTAPI` v2 (enum / char / distinct-over-scalar parameters)** —
  sub-item of #B above.
- **MT EventBroker / MT RequestBroker behavior changes.** Round 2 only
  touches the FFI surface and the courier infrastructure. The MT
  brokers stay intact and continue to serve genuine nim-to-nim
  cross-thread `.request` / `.emit` callers with their current typed
  slab mechanism.

### Success criteria

- Event delivery: foreign-thread CBOR callback fires from a single
  courier-style hop instead of `provider → MT slab → delivery thread →
  CBOR encode`. Wrappers see no surface change. ASAN + the existing
  parity matrices stay green under both `--mm:orc` and `--mm:refc`.
- Flag surface: `registerBrokerLibrary` no longer parses an `ffiMode:`
  field. `BrokerFfiMode` enum + `parseFfiModeLiteral` /
  `resolveFfiMode` removed. Existing call sites (no library in the repo
  sets `ffiMode:` after Phase 2c) keep compiling unchanged.
- `USE_CBOR` ifdef arms in `test/typemappingtestlib/test_typemappingtestlib.cpp`
  + `test/ffibench/bench_driver.cpp` resolved to a single
  CBOR-only path. The CMake `target_compile_definitions(... USE_CBOR=1)`
  lines go with them.
- Typed C wrapper: a minimal `<lib>_c.h` / `<lib>_c.c` pair that
  exposes one C function per request and one register/unregister pair
  per event, hiding the CBOR transcode internally. Pure-C examples
  (`examples/ffiapi/example/main.c`, `test/cmake_consumer/smoke.c`)
  un-gated and back on CI.

---

## 2. Baseline — relevant parts of the current state

References gathered while drafting:

- **Request courier** (in place since commit 92b7b90; lock-free MPSC
  ring since cc481c8):
  - `brokers/api_library.nim` — `_call` enqueues a `CborCallMsg`
    (`apiName[64]`, `reqBuf`, `reqLen`, `slotIdx`) into `courier.ring`,
    fires `courierSig.fireSync()`, blocks on the response slot.
  - Processing thread runs `courierPoll()`, drains
    `courier.ring.tryDequeue()`, `asyncSpawn`s `handleCourierMsg()`
    which CBOR-decodes, awaits `<Type>.request(...)` (same-thread,
    direct provider call), CBOR-encodes the response into a shared-heap
    buffer, and writes the response slot.
  - The dispatcher poller is registered through
    `mt_broker_common.nim`'s shared infrastructure
    (`registerBrokerPoller`, `brokerDispatchLoop`, `fireBrokerSignal`).

- **Event delivery (today, unchanged)**:
  - `brokers/api_library.nim` generates a per-event installer +
    handler. The provider side calls `.emit` on the processing
    thread.
  - That `.emit` reaches MT EventBroker, which marshals the typed
    payload into the MT slab, signals the delivery-thread bucket, and
    the delivery-thread coroutine unmarshals → typed Nim object →
    CBOR-encodes into a shared-heap buffer → calls the registered
    foreign callback with `(ctx, eventName, payloadBuf, payloadLen,
    userData)`.
  - This means the typed-marshalling crossing the courier eliminated
    on the request side is still paid on the event side.

- **Compile-flag / mode surface**:
  - `brokers/internal/api_ffi_mode.nim` — `BrokerFfiMode` is a
    one-value enum (`mfCbor`); `-d:BrokerFfiApiNative` is a `{.fatal.}`
    pointing back at round 1 doc; `parseFfiModeLiteral` errors on
    `"native"`; `resolveFfiMode` is a no-op consistency check.
  - `brokers/api_library.nim` — `parseLibraryConfig` still parses the
    optional `ffiMode:` field into the config tuple
    (`api_library.nim:60-144`); `registerBrokerLibraryImpl` calls
    `resolveFfiMode(...)` and discards the result (line 183).
  - Macro entry guard: `when defined(BrokerFfiApi) or
    defined(BrokerFfiApiCBOR)` — `BrokerFfiApiNative` removed in
    commit 6371336.

- **Generated C surface**:
  - `<lib>.h` + `<lib>.hpp` are emitted by
    `api_codegen_cbor_h.nim` / `api_codegen_cbor_hpp.nim`. Pure-C
    consumers see only the fixed 11-function ABI; the typed surface
    lives in the `.hpp` (`jsoncons`-backed). `examples/ffiapi/example/main.c`
    and `test/cmake_consumer/smoke.c` are kept in tree but gated with
    `if(FALSE)` in their respective CMake files (commit c31dcea).

---

## 3. Part D — Event courier (priority 1)

### 3.1 The change

Move the CBOR encode of an event payload + the foreign-callback fan-out
**off the delivery thread**, onto the **provider thread** (the same
processing thread that runs `setupProviders(ctx)` and the request
courier handlers). The delivery thread becomes a thin courier
consumer: receive an opaque CBOR buffer, look up the subscribers for
that `(ctx, eventName)`, hand the buffer pointer to each foreign
callback, drop the buffer when the last callback returns.

Equivalently: invert the current crossing. Today the typed payload
crosses processing → delivery; CBOR encode happens after the crossing.
After Part D, the CBOR encode happens **before** the crossing, on the
processing thread, and what crosses is the opaque buffer pointer.

### 3.2 Target sequence

```
 [processing thread — provider]                 [delivery thread]
   .emit(EventPayload{...}) on `<Type>`
     │ encode → shared-heap respBuf, len
     │ enqueue (eventTypeId, buf, len, refcount=N)
     │ fire courier-events signal
 ════╪═══ crossing (opaque buffer ptr) ═══╪════
     │                                    ▼
     │                       snapshot subscribers for (ctx, evtId)
     │                       for each subscriber:
     │                          foreignCb(ctx, name, buf, len, userData)
     │                       when last callback returns:
     │                          deallocShared(buf)
```

### 3.3 Code-change locations (proposed)

| Location | Change |
|---|---|
| `brokers/internal/mt_broker_common.nim` | Reuse the existing poller dispatcher. A second poller per library, dedicated to events, mirrors the request courier hook. |
| `brokers/api_library.nim` — generated per-event registrar + handler | The processing-thread `.emit` path is replaced with: `cborEncodeShared` → enqueue an `EventCourierMsg{ evtTypeId, buf, len, ctx }` into a per-library MPSC ring → fire signal. |
| `brokers/api_library.nim` — subscriber registry | Stays on the delivery thread (so foreign callback invocation rules don't change). The delivery-thread poller drains the new ring and fans the opaque buffer out to the snapshotted subscriber set. |
| `brokers/internal/api_event_broker_cbor.nim` | Adapter procs change shape: emit a `cborEncodeShared(payload)` directly into the courier ring instead of going through the MT EventBroker `.emit`. The MT EventBroker is no longer crossed for FFI events. |
| `brokers/api_library.nim` — `_shutdown` | The new event courier ring needs the same drain-and-fail discipline as the request courier (round 1, §6.4). On teardown, drain queued events without invoking callbacks; ensure no in-flight buffer is freed twice. |

The MT EventBroker stays intact for nim-to-nim event listeners — same
"genuine cross-thread `.emit`" contract round 1 preserved for
`.request`. The FFI path bypasses it.

### 3.4 Memory & thread safety (the critical section)

Mirror the round-1 §6.4 checklist:

1. **Buffer ownership.** The payload buffer is allocated on the
   processing thread by `cborEncodeShared` (existing helper, shared
   heap, not GC). It carries a fan-out refcount equal to the number of
   subscribers snapshotted at dequeue time. The delivery thread
   decrements the refcount after each callback returns; the final
   decrement frees. Exactly one allocation; exactly one free.
2. **No GC object crosses a thread.** Same property as the request
   courier: scalars + a shared-heap pointer only.
3. **Subscriber registry remains delivery-thread-owned** so callback
   timing, ordering, and registration semantics (`on_<Event>` /
   `off_<Event>` from the user-side wrappers) are unchanged.
4. **Shutdown race.** If `<lib>_shutdown(ctx)` runs while an event is
   queued, drain the ring on teardown and free each pending buffer
   without invoking callbacks. Symmetric to the request shutdown
   discipline.
5. **Backpressure.** Bounded MPSC ring (matches the request courier).
   On full ring, the provider-side `.emit` returns `err(...)` (events
   are fire-and-forget, but the broker convention is to surface drop).
   Document the new sentinel.
6. **Reentrancy.** A foreign callback that synchronously calls back
   into the library (`<lib>_call`) hits a different ring (the request
   courier) — no deadlock by construction.

### 3.5 Test additions

- Reuse `test/ffibench/stress_mt.cpp` and `stress_shutdown.cpp` as
  templates. Add an event-side stress driver that
  (a) registers K listeners across M threads, emits events at a
  sustained rate, asserts no drops and no UAF; and
  (b) issues `_shutdown` mid-stream, asserts every queued event is
  either dispatched fully or dropped cleanly.
- Cross-mode parity matrix already covers the wrapper-visible event
  surface (no surface change). The round 2 verification is
  ASAN-driven, not coverage-driven.

---

## 4. Part E — Compile-flag + `ffiMode:` simplification (priority 2)

### 4.1 The change

Today the surface still pretends two modes might exist:

- `BrokerFfiMode` — a one-value enum (`mfCbor`).
- `brokerFfiMode*` const — always `mfCbor`.
- `parseFfiModeLiteral`, `resolveFfiMode`, `gApiResolvedFfiMode`,
  `gApiResolvedFfiModeSet` — single-mode plumbing kept "to minimize
  churn".
- `registerBrokerLibrary` body — accepts an `ffiMode:` field that no
  one in the repo sets after commit c31dcea.

Round 2 collapses all of that:

- Drop `BrokerFfiMode`, `parseFfiModeLiteral`, `resolveFfiMode`,
  `gApiResolvedFfiMode`, `gApiResolvedFfiModeSet`,
  `brokerFfiApiCborForced`.
- Drop the `ffiMode:` parsing branch in
  `brokers/api_library.nim:parseLibraryConfig`. Setting `ffiMode:` in
  a library body becomes an unknown-field compile error.
- Keep the `{.fatal.}` on `-d:BrokerFfiApiNative`; that diagnostic
  still matters for stale build scripts.
- `-d:BrokerFfiApiCBOR` becomes a back-compat alias for `BrokerFfiApi`
  (one-release deprecation). The macro entry guard collapses to
  `when defined(BrokerFfiApi) or defined(BrokerFfiApiCBOR):` →
  `when defined(BrokerFfiApi):` after the deprecation window.

### 4.2 Code-change locations

| Location | Change |
|---|---|
| `brokers/internal/api_ffi_mode.nim` | Delete `BrokerFfiMode` + the `parseFfiModeLiteral` / `resolveFfiMode` / `brokerFfiMode` / `gApiResolvedFfiMode` / `gApiResolvedFfiModeSet` / `brokerFfiApiCborForced` block. Keep only the `{.fatal.}` guard on `-d:BrokerFfiApiNative` and a one-line module docstring pointing at this doc. The module shrinks to ~10 lines. |
| `brokers/api_library.nim:parseLibraryConfig` | Drop the `ffiMode:` field, drop the `ffiMode` and `ffiModeExplicit` slots from the returned config tuple, drop the parsing branch (lines 60-144). |
| `brokers/api_library.nim` — `registerBrokerLibraryImpl` | Drop the `discard resolveFfiMode(...)` consistency call (line 183). |
| `brokers/api_library.nim` — `registerBrokerLibrary` macro guard | Add a deprecation warning when `-d:BrokerFfiApiCBOR` is set on its own (no `BrokerFfiApi`); plan to remove `BrokerFfiApiCBOR` recognition one release later. |
| `brokers/internal/api_common.nim` | Drop the `export api_ffi_mode` line (or keep it — the file collapses but stays). |
| Tests + examples | No source changes expected; just CI/nimble flag normalization (use `-d:BrokerFfiApi` everywhere). |

### 4.3 Backward compatibility

The `ffiMode:` field has been a no-op consistency check since round 1
Phase 2c; no in-tree code sets it. We do not need a deprecation step
for it — Round 2 can drop it outright. The reduced macro will reject
the field as unknown, which is the desired diagnostic for any external
user still carrying it: a clear compile-time error referencing this
plan.

`-d:BrokerFfiApiCBOR` IS used in:
- `brokers.nimble` (every CBOR task)
- `.github/workflows/ci.yml`
- `doc/CBOR_Refactoring.md`, `doc/FFI_API.md` etc.

The deprecation alias keeps all of those compiling unchanged; the
follow-up release flips them to `-d:BrokerFfiApi`.

### 4.4 Test plan

- Negative test: a library with `ffiMode: "cbor"` in its body now
  fails to compile with the "unknown field" diagnostic. Add to
  `test_api_cbor_library_init.nim` as a `compileTimeFails(...)` probe.
- Positive: existing tests / examples continue to compile + run with
  no source changes.

---

## 5. Part F — `USE_CBOR` ifdef sweep (priority 3)

Five `#ifdef USE_CBOR` arms remain in
`test/typemappingtestlib/test_typemappingtestlib.cpp` plus one in
`test/ffibench/bench_driver.cpp`. The CMake side defines `USE_CBOR=1`
unconditionally (commit 0370821), so each `#ifdef USE_CBOR` arm is
always-true and each `#else` (if any) is dead.

| Location | Change |
|---|---|
| `test/typemappingtestlib/test_typemappingtestlib.cpp` lines 247, 261, 339, 1355, 2468 | Strip the `#ifdef USE_CBOR` guards; lift the always-true arm to unconditional. Drop any `#else` block. |
| `test/ffibench/bench_driver.cpp` line ~23 | Same. |
| `test/typemappingtestlib/CMakeLists.txt`, `test/ffibench/CMakeLists.txt` | Drop the `target_compile_definitions(... USE_CBOR=1)` line once the `#ifdef`s are gone. |

Pure mechanical change; verified by `nimble runTypeMapTestLibCborCpp`
(must stay 119/119) and `test/ffibench/bench_driver` running clean.

---

## 6. Part G — Typed C wrapper for pure-C consumers (priority 4)

Restores the consumer ergonomics that the native retirement
temporarily removed (round-1 §1, §4.5). Out-of-scope discussion items:

- **Where does the CBOR codec live?** Three options, in increasing
  vendoring cost: (a) pull in `TinyCBOR` (header + small .c file,
  permissive license), (b) pull in `QCBOR`, (c) generate a
  dependency-free subset codec from the schema registry (smallest blob,
  largest codegen work).
- **What is the generated surface?** One C function per request,
  taking typed scalars / pointer+length pairs / opaque `<lib>_event_t`
  for objects. Events keep a `<lib>_subscribe_<Event>(callback,
  userData) -> handle` / `<lib>_unsubscribe_<Event>(handle)` pair.
- **Buffer lifetime in C.** Owning vs. borrowing must be explicit.
  Proposal: per-request response is allocated by the library and freed
  by `<lib>_free_<Request>_response(...)`, mirroring the historical
  native ABI. The deferred `FASTAPI` zero-allocation path may relax
  this later.

### 6.1 Code-change locations (sketch)

| Location | Change |
|---|---|
| New: `brokers/internal/api_codegen_typed_c.nim` | Emits `<lib>_c.h` + `<lib>_c.c` from `gApiTypeRegistry` + `gApiCborRequestEntries` + `gApiCborEventEntries`. |
| `brokers/api_library.nim` | Hook the new codegen into `registerBrokerLibraryCborImpl`, gated by a new compile flag (`-d:BrokerFfiApiGenTypedC`, off by default). |
| `examples/ffiapi/example/main.c` | Un-gate; rewrite against `<lib>_c.h`. |
| `test/cmake_consumer/smoke.c` | Un-gate; rewrite against `<lib>_c.h`. |
| `examples/ffiapi/CMakeLists.txt`, `test/cmake_consumer/CMakeLists.txt` | Drop the `if(FALSE)` wrappers (commit c31dcea); link smoke binaries against the new typed C surface. |
| `brokers.nimble`, `.github/workflows/ci.yml` | Re-add `runFfiExampleC` / `testFfiApiCmake` driving the new typed C build. |
| `doc/FFI_API.md`, `doc/TYPESUPPORT.md`, `doc/TYPE_SURFACE.md` | Restore the C column to the matrix; document the typed-C wrapper. |

### 6.2 Risk

- **CBOR codec dependency** — picking (a) TinyCBOR is the most
  pragmatic option; needs license + vendoring discipline (mirrors the
  jsoncons / cbor2 / ciborium / fxamacker-cbor handling already in
  place for the other wrappers).
- **Object-as-request-param + nested objects** in C ergonomics — these
  work in CBOR but require careful C struct lifetime decisions.
  Object-as-param can be `<lib>_request(ctx, const <T>* tag, …)` with
  the C consumer owning the input struct (read-only).

### 6.3 Effort

Largest item in Round 2 — easily 5–7 days. Worth a separate
mini-plan / RFC once Parts D and E are in.

---

## 7. Part H — Local janitorial

Smallest items, mostly hygiene:

- Delete stale `cmake-build/`, `cmake-build-asan/`, `cmake-build-n224/`
  directories under `test/typemappingtestlib/` and any other
  pre-retirement build artifacts that aren't covered by `.gitignore`.
- `test/ffibench/benchlib.nim` — header was refreshed in commit
  16d8c7b; check the rest of the file (the `VecRequest carries
  seq[int32]…` paragraph rationale still mentions native vs. CBOR
  surface differences that no longer exist).
- `doc/FFI_API.md` — round-1 left a banner at the top and didn't
  rewrite the 1689-line body. After Parts D + E, the body's diagrams
  and references to the typed C surface can be reconciled. Either a
  full rewrite or a section-by-section sweep, whichever the maintainer
  prefers.
- Audit comments in `brokers/internal/api_request_broker_cbor.nim`,
  `api_event_broker_cbor.nim`, `api_codegen_cbor_*.nim` that still
  describe historical native-vs-CBOR contrasts.

---

## 8. Sequencing & effort

| Phase | Work | Why this order | Effort | Risk |
|-------|------|----------------|--------|------|
| 1 | **Part E** — flag + `ffiMode:` collapse | Mechanical, unblocks docs + ergonomic improvements before any new feature lands | 0.5–1 d | low |
| 2 | **Part D** — event courier | Biggest correctness item; benefits from a clean compile-flag surface to design against | 4–6 d | **med-high** (shutdown race + refcount discipline) |
| 3 | **Part F** — USE_CBOR ifdef sweep | Tiny, do after Part D so the event-side test sources are only edited once | 0.25 d | low |
| 4 | **Part H** — janitorial | Catches anything that drifted during Parts D/E | 0.25–0.5 d | low |
| 5 | **Part G** — typed C wrapper | The heaviest item; deserves its own RFC. Schedule after Parts D/E ship and stabilize. | 5–7 d | **med** (codec choice + lifetime contract) |

Round 2 total without Part G ≈ **5–8 days**.
Part G alone is a separate work-week.

---

## 9. Risk register

| Risk | Severity | Mitigation |
|------|----------|------------|
| Event courier refcount races (subscriber set mutates while fan-out is in flight) | **high** | Snapshot-and-clone the subscriber set on the delivery thread, exactly the way the request courier snapshots before dispatch; refcount is per-message, not per-buffer-pool |
| Event shutdown race (lib teardown while events queued) | **high** | Mirror request courier §6.4 ordering: stop accepting `emit` enqueues → drain ring (free buffers, do not invoke callbacks) → join delivery thread → free pools |
| Event ordering across subscribers changes vs. today | med | Document explicitly; today's ordering is "delivery thread iterates registered callbacks in registration order" and the courier path preserves that |
| `-d:BrokerFfiApiCBOR` alias removal breaks downstream | low | One-release deprecation; warn in macro entry; update CI + nimble + docs to `-d:BrokerFfiApi` simultaneously |
| Typed C wrapper choice of CBOR codec (TinyCBOR vs. QCBOR vs. generated) | med | Defer to Part G RFC; vendoring policy mirrors existing wrappers |
| Stale doc text after Part E | low | Sweep `doc/FFI_API.md` + the codegen module docstrings as part of Part H |

---

## 10. Deferred to a later round (carried over from CBOR_Refactoring.md §10)

- **`FASTAPI` annotation (Part B)** — positional CBOR array for
  scalar-only brokers. Per user direction, **still deferred**.
- **`FASTAPI` zero-allocation request** — sub-item of #B.
- **`FASTAPI` v2** — enum, `char`, distinct-over-scalar parameters.
  Sub-item of #B.
