# Hierarchical (OOP-ish) Brokers — Implementation Plan

Branch: `hierarchical_brokers` (from `master` @ 74799f7).

---

## ⮕ REVISED ROADMAP (post-P7, supersedes the original P5/P6 FFI sections below)

P1–P4 + P5(in-proc factory) + P6-core(bindToContext) + P7(unit tests) are
**done & committed**. The FFI multi-interface design was re-scoped with the
user. Remaining work, in execution order: **D → B → reduced-A**.

### Decisions (this revision)
- **No** hierarchical *Nim ownership*, **no** cascade in Nim, **no** cross-`.so`
  (interface in one lib + impl in another). Dropped.
- **Multi-interface within ONE library**: one **main** `BrokerInterface(API)` =
  the library (its `createContext`/`shutdown` embed into the main wrapper class,
  exactly as today). Every **other** `BrokerInterface(API)` → its **own wrapper
  class in its own header**.
- **Library-global brokers live INSIDE the main interface** (they're tied to the
  library context / thread / resource lifecycle). No top-level flat API brokers.
  **Broker-name / apiName collisions across the whole library = HARD compile
  errors.**
- **Create-instance request**: any API request (main or sub) may return a
  **sub-interface instance** — typed as the sub-interface ref (`IWidget`) in Nim;
  serialized as the instance `BrokerContext` (the `instanceCtx` half) over FFI.
- **Ownership is in the WRAPPER (RAII), not Nim**: the foreign wrapper object
  returned for a created sub-instance **owns** it and drives teardown
  (C++ `unique_ptr<T>` / dtor; Rust `Drop`; Go `runtime.SetFinalizer`+`Close`;
  Python `__del__`/`close`/context-mgr; C explicit free fn). Per-language
  ownership must be examined.
- **Library shutdown sweeps** any still-live sub-instances (safety net): a
  per-context registry of live sub-instances; main `shutdown` closes the
  remainder. So teardown is guaranteed even if a wrapper leaks.
- C (custom error `E`, MultiRequestBroker sugar) — **not needed now**.

### Phase D — formal testing of the CURRENT (single main interface) capability
- **D1** `examples/ffiapi/hierlib`: one main `BrokerInterface(API)` +
  `BrokerImplement` + `bindToContext` + `registerBrokerLibrary`, with C/C++/
  Rust/Go/Py wrappers + nimble tasks + CI list (mirrors `examples/ffiapi`).
  Turns the proven core into a reviewable, CI-guarded artifact. (Single
  interface; reduced-A extends it to multi-interface.)
- **D2** refc: instance is GC-freed after `close()` (not just providers cleared).
- **D3** multi-thread interface dispatch test (cross-thread, real MT lane).
- **D4** compile-fail/negative tests: apiName collision, cross-interface broker
  name collision, object-payload/name mismatch, mixed-case sigs in one block.

### Phase B — lifecycle / memory robustness (all 🔴 important)
- **B1** `=destroy` on the impl → `close()` when `brokerCtx != Default`; tested
  on refc + orc.
- **B2** event-listener cleanup in `close()`: the interface registers a teardown
  hook enumerating its event types so `close()` drops listeners too.
- **B3** gcsafe `new()`/`create()`: atomic `classCtx` allocator + once-init so
  `create()` is callable on the FFI processing thread (re-add gcsafe to the
  factory path).
- **B4** factory storage cross-thread (lock / shared cell, not a bare global).
- **B5** `classCtx` lazy-init race fix (atomic) — folds into B3.

### Phase reduced-A — multi-interface FFI library
- **A1** main interface = library lifecycle in the main wrapper class; global
  brokers fold into the main interface; cross-library collision check (hard err).
- **A2** compile-time interface registry; emit one wrapper class + header per
  `BrokerInterface(API)`; only the main gets `createContext`/`shutdown`.
- **A3** create-instance request → returns `IWidget`; provider constructs the
  instance under the lib's ctx scheme; FFI returns the `instanceCtx` handle.
- **A4** wrapper RAII ownership + teardown per language (C++/Rust/Go/Py/C).
- **A5** per-context live-sub-instance registry + library-shutdown sweep.
- Extend `hierlib` to multi-interface; verify across all wrappers.

---


## Goal

Add an interface/implementation (pure-virtual-like) layer over the existing
broker macros so brokers can be owned by an object instance, while **keeping
the current flat broker facade byte-for-byte intact**. Add a convenience
proc-style RequestBroker signature sugar. Expose the interface model through
the FFI layer (one interface = one library) with all wrapper languages.

## Non-negotiable guardrails

1. **Backward compatibility is a gate, not a goal.** Every existing test
   (`nimble test`, `nimble testApi`, all `runTypeMapTestLib*` / `runFfiExample*`)
   must compile and pass unchanged after *every* phase. This is the proof that
   the prior syntax is still available exactly as before. The legacy
   `RequestBroker:` / `type X = …` / `proc signature*(…)` path stays untouched;
   all new behavior is additive and selected by detecting the new forms.
2. **No `git push` / no commit** until explicitly asked.
3. **Memory-model discipline.** Every new lifetime-bearing construct states its
   behavior under `--mm:refc` and `--mm:orc`. The refc closure-cycle hazard
   (instance → bucket → provider closure → instance) is addressed by
   deterministic `close()`, not by relying on the cycle collector.
4. **GitNexus impact** is run on each cross-module symbol before editing it
   (`broker_context`, the `RequestBroker` macro, `api_request_broker_cbor`,
   `registerBrokerLibrary`). HIGH/CRITICAL risk is surfaced before proceeding.

---

## Design summary (from the ideation thread)

### Context split
`BrokerContext = distinct uint32` is reinterpreted as two `uint16` halves:

```
bits [15:0]  → classCtx     (broker-object/interface type, ≤ 65535)
bits [31:16] → instanceCtx  (instance of that class, ≤ 65535)
```

Flat brokers keep `classCtx == 0`, so `DefaultBrokerContext == 0x0000_0000`
and `NewBrokerContext()` continues to allocate in the lower 16 bits with the
upper half zeroed. Bucket lookup is unchanged — still keyed by the full
`uint32`; the split is purely semantic.

### Interface / implementation
- `BrokerInterface IFace:` block (events + requests) → abstract, non-instantiable
  base. Generates: hidden `brokerCtx` field, instance-scoped `emit`/`listen`
  facade for events, one abstract `{.base, async: (raises: []), gcsafe.}`
  `method` per request, plus the factory broker.
- `type Impl = ref object of IFace` declared idiomatically; behavior attached by
  the **`BrokerImplement Impl of IFace:`** macro, which contains an `init(...)`
  block and **raw `method` definitions**:
  ```nim
  type MyServiceImpl = ref object of IMyService
    db: Database
  BrokerImplement MyServiceImpl of IMyService:
    init(db: Database): self.db = db
    method getHealth(self: MyServiceImpl): Future[Result[GetHealth, string]]
        {.async: (raises: []).} = GetHealth(...)
  ```
  Requests use Nim single-dispatch `method`; events get no method (only context
  plumbing).
- The macro wraps the user's raw overrides with `new`/`setupProviders`/`close`
  (it does **not** synthesize method bodies), stamps a **byte-identical**
  async/raises/gcsafe pragma alignment requirement on base + overrides
  (Future-type identity is the sharp edge), and verifies at compile time that
  every abstract request is overridden.

### FFI codegen is opt-in per interface — `BrokerInterface(API)`
- An interface that needs FFI codegen is declared `BrokerInterface(API) IFace:`.
  The `(API)` marker **propagates to every EventBroker / RequestBroker** inside
  it, making them `(API)` brokers automatically (no per-broker annotation).
- A library is **not** one-interface. It has **one main interface as the
  first-class facade** (the only one exposing `<lib>_createContext()`), but the
  build still generates the C ABI + all wrappers for the **other `(API)`
  interfaces** too (used as sub-interfaces / owned children).

### Instance-ctx ↔ object association
Hybrid: providers registered **per instance** as closures capturing `self`
(the closure environment *is* the ctx→self binding, reusing the existing
per-context provider model) **plus** a per-class ownership table
`Table[uint16 /*instanceCtx*/, IFace]` (threadvar on the FFI processing thread)
used only for lifetime/shutdown/FFI reachability.

### Factory / proxy / DI
`BrokerInterface` also emits a global single-provider **factory** broker:
- `IFace.provideFactory(f)` — last registration wins.
- `IFace.create(args…)` — **accepts inputs** so a factory can pick an impl from
  config/outer circumstances.
A proxy is just-another implementation of the interface whose method bodies
forward. Same `create()` returns either the real impl (same Nim runtime,
direct virtual dispatch, zero serialization) or a generated `IFaceProxy`
(separate runtime / `.so`, forwards via CBOR over `_call` / `_subscribe`).
Consumer code is identical across both.

### RequestBroker proc-sugar (option B, decoupled)
- One broker per `RequestBroker:` block (two signature slots: zero-arg +
  arg-based). Case convention: types Capitalized, procs lowercase; `getHealth`
  ↔ broker `GetHealth`. New syntax is proc-based only (legacy `signature*` still
  accepted for backward compat); the two slots are distinguished by arity and
  paired by name.
- Option B: payload type is decoupled from the broker tag. POD form
  `proc getVersion(): Future[Result[string, string]]` → broker `GetVersion`,
  raw `string` payload. Object form pairs an explicit `type GetHealth = object`
  with `proc getHealth(): Future[Result[GetHealth, string]]`.

### Wrapper method naming (overloading is a hard no-go: Rust/Go error,
Python silently shadows — only C++ overloads)
- single signature → bare broker name.
- both slots present → zero-arg keeps bare `<brokerName>`; arg-based →
  `<brokerName>Arg` (apiName `<base>_arg`). Casing per wrapper convention.

### FFI error type (CONFIRMED)
FFI errors are **pinned to `string`**. Custom `Result[T,E]` error types are
honored only for in-process (same-runtime) brokers; the CBOR envelope keeps its
`string` error field. apiName collisions are a **hard compile error** naming
both colliding brokers (no silent auto-suffix).

### FFI ownership hierarchy (CONFIRMED)
`registerBrokerLibrary` optionally designates **one main interface class**:
- Only the main class exposes `<lib>_createContext()`. `<lib>_shutdown(ctx)` /
  its destructor tears down the **entire** context — processing + delivery
  threads, all owned sub-instances, the whole library.
- `InitializeRequest` (post-create config broker) **accepts the main class's
  `factoryCreate`**; the `InitializeRequest` payload supplies the factory inputs.
- When **>1** interface is defined, the main class creates **sub-interface
  implementations** at runtime (main → subs ownership). Sub-interface foreign
  wrappers control **only** that sub-instance's lifetime (clear its providers /
  listeners) — never threads or the library context.
- Maps onto the context split: main = `classCtx_main`, each sub = its own
  `classCtx_n`, instances differ by `instanceCtx`. The per-class ownership table
  tracks instances; `main.close()` **cascades** to owned sub-instances before
  stopping the threads.

### `implement` body form (CONFIRMED)
The `implement Impl of IFace:` block contains **raw `method` definitions**
(`method getHealth(self: Impl): … =`), not a `request X:` sugar. The macro
wraps them with `new`/`setupProviders`/`close` but does not synthesize the
method bodies — closer to plain Nim, no hidden body codegen.

---

## Phases (each ends with the backward-compat gate green)

### Phase 0 — Baseline
- Run the full suite on the fresh branch and record green:
  `nimble test`, `nimble testApi`, `nimble runTypeMapTestLibCpp/Py/Rust/Go`,
  `nimble runFfiExampleCpp/Py/Rust/Go`.
- Capture timings/output to compare against later phases.
- **Verify:** all green. No code changes.

### Phase 1 — Context split (foundation)
- `brokers/broker_context.nim`: add `classCtx(ctx): uint16`,
  `instanceCtx(ctx): uint16`, `makeBrokerContext(classCtx, instanceCtx): BrokerContext`.
  Keep `DefaultBrokerContext = 0`, `NewBrokerContext()` lower-16-bit allocation.
- No change to bucket lookup or any existing dispatch.
- GitNexus impact on `BrokerContext`, `NewBrokerContext`.
- **Verify:** full suite unchanged-green (the split is inert until used).
- **Memory model:** atomic counter for instanceCtx allocation is the same
  `fetchAdd` machinery already used; refc/orc identical.

### Phase 2 — RequestBroker proc-sugar + option B (orthogonal, lands first)
The interface model depends on this, so it ships before the OOP macros.
- Add a front-end detector in the `RequestBroker` macro path: legacy form
  (`proc signature*`) → existing code untouched; new form (lowercase proc /
  `<Name>()` / `<Name>___`) → new desugar.
- New desugar lowers to the internal representation already consumed by the
  backend (broker tag, zero/arg slots, arg params, payload type, error type).
- **Option B decoupling** (only on the new path): separate the dispatch-handle
  type from the payload type. Generalize `isReturnTypeValid`
  (request_broker.nim:188–214) to *extract* Ok/Err from `Result[T,E]` rather
  than assert `Ok == typeIdent` and `Err == string`.
- Wrapper naming rule at api_request_broker_cbor.nim:358–391
  (`zeroApiSuffix → ""` always; `argApiSuffix → "_arg"` only when a zero-arg
  sibling exists). Add a **compile-time apiName uniqueness assertion** with an
  error naming both colliding brokers.
- Apply the same front-end to `(sync)`, `(mt)`, `(API)` flavors (shared parser).
  MultiRequestBroker deferred.
- FFI error type per the confirmed decision.
- GitNexus impact on the `RequestBroker` macro, `collectSignatures`,
  `isReturnTypeValid`, `registerCborRequestEntry`.
- **Verify:** legacy tests green (they use `signature*` → untouched path);
  add new sugar unit tests (below).

### Phase 3 — `BrokerInterface` macro (abstract base)
- New module `brokers/broker_interface.nim` (+ helpers under `internal/`).
- Emits: `type IFace = ref object of RootObj` with hidden `brokerCtx`;
  per-class `classCtx` (compile-time/init atomic); abstract
  `{.base, async: (raises: []), gcsafe.}` method per request (raises
  `AssertionDefect` default); instance-scoped `emit`/`listen` facade for events
  (inject `self.brokerCtx`); the factory broker (`create`/`provideFactory`).
- Non-instantiable: no `new` generated; direct construction yields a base with
  no providers (request → `err`).
- **`BrokerInterface(API)` variant**: the `(API)` marker propagates to every
  EventBroker / RequestBroker declared inside the interface, lowering them to
  `(API)` brokers (FFI codegen) without per-broker annotation. Plain
  `BrokerInterface` (no `(API)`) is in-process only.
- Reuses Phase-2 sugar so the interface block reads as pure-virtual signatures.
- **Verify:** full legacy suite green; interface-only compile tests.
- **Memory model:** `method` dispatch is RTTI-based, identical under refc/orc;
  async-method Future identity enforced by codegen.

### Phase 4 — `BrokerImplement` macro (derived implementation)
- `BrokerImplement Impl of IFace:` with an `init(...)` block and **raw `method`
  definitions** (`method getHealth(self: Impl): … =`). The macro does NOT
  synthesize method bodies; it wraps the user's overrides with `Impl.new(...)`,
  `setupProviders(self)` (per-instance provider closures capturing `self`),
  `registerInstance`, `close(self)`, and `=destroy` → `close` when
  `brokerCtx != Default`.
- Compile-time completeness check: every abstract request method is overridden;
  the override signature must match the `{.base.}` exactly (compiler-enforced).
- **Teardown sequence (local impl) — explicit, idempotent:**
  1. `clearProvider(self.brokerCtx)` for each request (breaks the refc cycle).
  2. `dropAllListeners(self.brokerCtx)` for each event.
  3. `gInstances.del(self.brokerCtx.instanceCtx)`.
  4. `self.brokerCtx = DefaultBrokerContext` (idempotency guard).
  - In-flight spawned work completes against its snapshot (existing semantics);
    callers releasing external resources must drain first.
- **Verify:** new nim-only impl tests (below); legacy suite green.
- **Memory model:** refc — `close()` MUST run to break instance↔closure cycle;
  `=destroy` covers GC-collected instances; under orc the cycle collector is a
  backstop only. Document both.

### Phase 5 — Factory (with inputs) + Proxy + cross-runtime teardown
- **Factory.** `BrokerInterface` emits a single-provider factory broker.
  `IFace.create(cfg…)` **accepts typed inputs** so a factory can pick/configure
  the impl from outer circumstances; `IFace.provideFactory(f)` — last wins.
  In-process, the factory returns the real impl ref (direct virtual dispatch,
  zero serialization).
- **Proxy = just-another impl.** Generate `IFaceProxy = ref object of IFace`
  (`handle: pointer`, `vt: ForeignVTable`) whose request `method`s encode CBOR →
  `vt.call(handle, "<apiName>", buf)` → decode envelope, and whose `listen`
  installs a foreign trampoline via `vt.subscribe`. The same `create()` returns
  the real impl (same runtime) or a proxy (separate runtime) — consumer code is
  identical.
- **Ownership is determined by the interface's role in the hierarchy, not a
  generic flag** (reconciled with Phase 6):
  - A **main-interface** proxy owns the whole foreign context. Its teardown is
    the *whole-context* path: `vt.shutdown(handle)` = `<lib>_shutdown(ctx)`,
    which on the remote tears down all owned sub-instances + processing/delivery
    threads.
  - A **sub-interface** proxy owns only its own remote sub-instance. Its
    teardown is the *instance-local* path: it clears its own subscriptions and
    calls the sub-interface's per-instance close entry — it must **not** stop
    threads or the library context (the main owns those).
  - The proxy carries an `isMain: bool` (set by the factory/createContext path)
    selecting which teardown branch runs in step 4 below.
- **Proxy teardown sequence (cross-FFI) — explicit, ordered:**
  1. Mark proxy closing (reject new calls/subscribes; idempotency guard).
  2. For each active event subscription: `vt.unsubscribe(handle, event,
     fHandle)` to remove the **FFI** subscription first.
  3. Drop the corresponding **Nim** trampoline closures (release captured env →
     breaks the cross-boundary cycle; required under refc).
  4. Role-dependent: **main** → `vt.shutdown(handle)` (whole-context, threads);
     **sub** → call the sub-instance's local close entry only.
  5. Null `vt`/`handle`; set `brokerCtx = Default`.
  - Ordering rationale: unsubscribe before dropping closures so no in-flight
    foreign callback can fire into a freed Nim closure; (main) shutdown last so
    the remote can drain.
- **Verify:** proxy + factory nim tests; FFI proxy round-trip in Phase 7.
- **Memory model:** trampoline env is GC-allocated; cross-runtime means the
  remote `.so` has its own GC — only the Nim-side closure/handle lifetime is
  ours to manage; document the boundary.

### Phase 6 — FFI integration (`registerBrokerLibrary`, hierarchy)
- The build generates the C ABI + **all wrappers (C/C++/Rust/Go/Py) for every
  `BrokerInterface(API)`** in the library — not just the main one. The
  difference is lifecycle surface, not codegen presence: **only the main
  interface gets `<lib>_createContext()`** and whole-context teardown; the other
  `(API)` interfaces get their typed call/subscribe/per-instance-close surface
  (used as owned sub-interfaces).
- `registerBrokerLibrary` designates **one main interface class**. Only the main
  class exposes `<lib>_createContext()`: it instantiates the main `Impl` via its
  factory (inputs fed by `InitializeRequest`) on the processing thread
  (`setupProviders`), spawns the delivery + processing threads, returns the
  composite `uint32` as the opaque handle.
- `_call` → `instance.request`, `_subscribe` → `instance.listen`.
- `<lib>_shutdown(ctx)` (main) → **whole-context teardown**: cascade
  `close()` to all owned sub-instances, then stop processing + delivery threads,
  then release the context. (Main-only; subs have no `createContext`/thread
  control.)
- **Sub-interfaces** (when >1 interface defined): created at runtime by the main
  impl; their foreign wrappers expose only per-instance lifetime control
  (`close` → clear that sub-instance's providers/listeners), never thread or
  library teardown.
- Reuse existing courier / three-lane dispatch unchanged; the dispatch table
  resolves a method override instead of a free provider.
- Wrapper codegen (C/C++/Rust/Go/Py) consumes the same `requestEntries` /
  event descriptors — no per-language changes beyond what Phase 2 introduces.
- Emit the Nim proxy alongside the foreign wrappers (same interface = single
  source of truth for: abstract methods, real impl, Nim proxy, foreign proxies).
- GitNexus impact on `registerBrokerLibrary`, `setupProviders`,
  `InitializeRequest`/`ShutdownRequest` wiring.
- **Verify:** new FFI example lib (below) builds + runs across all wrappers;
  main-context shutdown tears down threads; sub-instance close is thread-safe
  and local; legacy FFI examples/tests green.

### Phase 7 — Tests
- **Nim-only** (`test/`):
  - `test_request_broker_sugar.nim` — proc-sugar (POD + object), bare-vs-`Arg`
    wrapper naming, apiName-collision compile-fail test, option-B decoupling.
  - `test_broker_interface.nim` — abstract base, event emit/listen scoping by
    instance ctx, non-instantiability, `(API)` propagation to sub-brokers.
  - `test_broker_impl.nim` — `BrokerImplement`, method override dispatch, async
    requests, `close()` teardown + idempotency, refc cycle freed after close.
  - `test_broker_factory_proxy.nim` — factory-with-inputs, last-wins,
    in-process proxy == real impl indistinguishable to consumer.
  - Wire into `brokers.nimble` `test` task (ORC + refc, debug + release).
- **FFI** (`examples/ffiapi/hierlib/` — new):
  - One `nimlib/hierlib.nim` using `BrokerInterface(API)` + `BrokerImplement`,
    with a **main** interface plus at least one **sub-interface** to exercise
    the ownership hierarchy; covering an event, a single-sig request, a two-sig
    (zero + arg) request, a POD request, an object-payload request, and the
    `InitializeRequest`-fed factory.
  - Consumers/wrappers for **all** types: `example/` (C), `cpp_example/`,
    `python_example/`, `rust_example/`, `go_example/`, mirroring the ffiapi
    layout.
  - Nimble tasks: `buildHierExample`, `buildHierExampleCpp`,
    `runHierExample{Cpp,Py,Rust,Go}`; add to CI list in AGENTS.md.
  - Asserts cross-language parity (bare vs `Arg` method names, payload fidelity,
    event callback demux, lifecycle create/shutdown).
- **Backward-compat gate:** the entire pre-existing suite stays green.

---

## Files (anticipated)

| File | Change |
|------|--------|
| `brokers/broker_context.nim` | context split accessors (Phase 1) |
| `brokers/request_broker.nim` | sugar front-end detector + option-B (Phase 2) |
| `brokers/internal/mt_request_broker.nim` | sugar parity for `(mt)` |
| `brokers/internal/api_request_broker_cbor.nim` | naming rule, uniqueness assert, decoupled descriptor (Phase 2/6) |
| `brokers/internal/helper/broker_utils.nim` | shared sugar parsing helpers |
| `brokers/broker_interface.nim` | NEW — `BrokerInterface` / `BrokerInterface(API)` macro (Phase 3) |
| `brokers/broker_implement.nim` | NEW — `BrokerImplement` macro (Phase 4) |
| `brokers/internal/broker_proxy.nim` | NEW — proxy (main/sub) + factory codegen (Phase 5) |
| `brokers/api_library.nim` | interface→library mapping (Phase 6) |
| `brokers/internal/api_codegen_*` | Nim-proxy emission hook (Phase 6) |
| `test/test_*` | new nim tests (Phase 7) |
| `examples/ffiapi/hierlib/**` | NEW — FFI parity example (Phase 7) |
| `brokers.nimble`, `AGENTS.md` | tasks + CI list (Phase 7) |

---

## Resolved decisions (all confirmed)
1. **FFI error type** → pinned to `string`; custom `E` honored in-process only.
2. **apiName collision** → hard compile error naming both colliding brokers.
3. **FFI lifecycle ownership** → hierarchy: one main class owns
   `createContext` + whole-context/thread teardown; sub-interface wrappers
   manage only their own instance. `InitializeRequest` feeds the main class's
   `factoryCreate`.
4. **`implement` body** → raw `method` defs (no `request X:` body sugar).
```
