# Reduced-A — Multi-Interface FFI Library: Implementation Plan

**Self-contained plan for a fresh session.** Branch: `hierarchical_brokers`.
Read alongside the auto-memory `project_oop_brokers.md` (design history +
gotchas) and `doc/HIERARCHICAL_BROKERS_PLAN.md` (the revised roadmap top
section). This document is the executable spec for the final phase
("reduced-A"); everything before it (P1–P7, Phase D, Phase B) is committed and
green.

---

## 0. Where things stand (entry state)

- **Done & committed** on `hierarchical_brokers`:
  - P1 context split (`brokers/broker_context.nim`): `BrokerContext = distinct
    uint32`, low16 = `classCtx`, high16 = `instanceCtx`. Accessors
    `classCtx`/`instanceCtx`/`makeBrokerContext`/`newClassCtx`.
    `DefaultBrokerContext = 0x0000_0001`.
  - P2 RequestBroker proc-sugar + option B (decoupled payload) across
    single/mt/API + all wrappers. Shared parser `parseRequestSugar` in
    `brokers/internal/helper/broker_utils.nim`.
  - P3 `brokers/broker_interface.nim` — `BrokerInterface IFace:` /
    `BrokerInterface(API, IFace):`. Generates the `ref object of RootObj` type +
    hidden `brokerCtx`, abstract `{.base.}` async methods per request, a generic
    event facade (emit/listen/dropListener templates), and the factory
    (`provideFactory`/`create`). Also publishes the interface's event types to a
    compile-time registry (`registerInterfaceEvents`/`interfaceEvents` in
    broker_utils) for `close()` teardown.
  - P4 `brokers/broker_implement.nim` — `BrokerImplement Impl of IFace:` with
    `proc init(...)` + raw `method` overrides. Generates `Impl.new(...)`,
    `Impl.bindToContext(ctx, ...)` (adopts an external ctx; **gcsafe**),
    `<Impl>SetupProviders` (per-instance provider closures capturing `self`,
    gcsafe), and `close(self)` (clears providers + drops event listeners;
    idempotent). classCtx is an immutable module-level `let newClassCtx()`
    (race-free, gcsafe to read); instanceCtx from an atomic counter.
  - P5 in-process factory/DI (in `broker_interface.nim`).
  - P6-core: `bindToContext` lets a `BrokerInterface(API)` impl serve as
    `registerBrokerLibrary`'s `setupProviders(ctx)` provider set. The OOP model
    is consumable over FFI (single main interface).
  - Phase D: `examples/ffiapi/hierlib` (single main interface) with C++/Python/
    Rust/Go consumers + nimble tasks; lifecycle/cross-thread/compile-fail tests.
  - Phase B: race-free classCtx, event-listener cleanup in `close()`.
- **Test/verify commands** (all currently green): `nimble test` (36 cfg runs),
  `nimble testApi` (24), `nimble testSugarRejects`,
  `nimble runHierExample{Py,Cpp,Rust,Go}`, and the legacy
  `nimble runTypeMapTestLib{Cpp,Py,Rust,Go}` / `runFfiExample*`.
- **Key existing FFI codegen files**:
  - `brokers/api_library.nim` — `registerBrokerLibrary` (C ABI surface,
    createContext/shutdown, processing+delivery threads, calls free
    `setupProviders(ctx)`, `installAllListeners(ctx)`).
  - `brokers/internal/api_request_broker_cbor.nim` — RequestBroker(API) codegen:
    adapters + descriptor registration (`registerCborRequestEntry`,
    `registerCborObjectType`/`registerCborPrimitiveType`). apiName uniqueness is
    already a hard compile error here (`api_common.nim` ~line 117).
  - `brokers/internal/api_codegen_cbor_{hpp,py,rust,go}.nim` — per-language
    wrapper class generators (iterate the flat `requestEntries`/event
    descriptors and emit one `Lib` class).
  - `brokers/internal/api_schema.nim` — compile-time type registry
    (`gApiTypeRegistry`, `isTypeRegistered`, `lookupTypeEntry`).

## 1. Goal

One library may declare **multiple** `BrokerInterface(API)`. Exactly **one** is
the **main** interface (the library facade: it owns `createContext`/`shutdown`
and library-global brokers). Every other `BrokerInterface(API)` becomes its own
**wrapper class in its own header**. Any API request may **create and return a
sub-interface instance**; the foreign wrapper turns the returned handle into a
typed sub-wrapper object. The C ABI stays single (`_call`/`_subscribe` keyed by
`ctx` + `apiName`); only the *typed wrapper surface* is partitioned per
interface.

## 2. Confirmed decisions (resolved with the user)

1. **Main designation:** `registerBrokerLibrary` gains an explicit
   **`mainClass: IMain`** field. Other `BrokerInterface(API)`s are
   auto-discovered from a compile-time registry.
2. **Create-instance request:** the request's **Ok type is the sub-interface
   ref** — `proc makeWidget(...): Future[Result[IWidget, string]]`. The codegen
   recognizes registered interface types; on the wire the payload is the
   sub-instance's `BrokerContext` (uint32 routing handle); the wrapper builds a
   `Widget` class from it.
3. **Sub-instance construction:** the request **method body constructs it**
   (`WidgetImpl.new(...)` / `bindToContext`) and returns it; the adapter extracts
   its `brokerCtx`. The create-instance method is gcsafe (override pragma), so
   **`new()` must be gcsafe** (relies on the immutable-`let` classCtx + atomic
   instanceCtx already in place; the sub-impl's `init` body must be gcsafe).
4. **No FFI-side instance ownership.** Sub-instances live in Nim/GC-owned memory
   (kept alive by their provider closures, keyed by `instanceCtx`); the FFI/
   wrapper holds **only the ctx** as a routing channel. Teardown is therefore
   *not* "free the instance" (GC does that once providers are cleared) but:
   **drop that ctx's event listeners + drain/fan-out its in-flight requests**,
   then let GC reclaim. Any registry is **per-lib-context** — never mix multiple
   library contexts.
5. **Collisions:** broker / apiName collisions across the whole library are hard
   compile errors (apiName dup check already exists; extend to clearly name the
   colliding brokers/interfaces).

## 3. Design overview

- **Single C ABI, multiple typed classes.** `_call(ctx, apiName, buf)` /
  `_subscribe(ctx, event, cb)` are unchanged and shared. apiNames are globally
  unique across all interfaces (collision check). A `Widget` wrapper just calls
  `_call(widgetCtx, "widget_method", buf)`; the global dispatch table routes by
  apiName, and the adapter dispatches by `widgetCtx` to the right sub-instance's
  provider. So per-interface work is **wrapper-class/header partitioning + the
  create-instance handshake**, not new ABI.
- **Threads:** only the main interface's `createContext` spawns the processing +
  delivery threads. Sub-instance providers run on the **same** processing thread
  (created via a main request that runs there). One thread pair per library
  context.
- **Create-instance handshake:**
  - Nim: `makeWidget` provider builds `WidgetImpl.new(...)` (gcsafe), returns the
    `IWidget`. The generated adapter detects the interface-typed payload,
    extracts `widget.brokerCtx`, and CBOR-encodes that `uint32` as the response.
  - Wire: `{ ok: <uint32 ctx> }` (or `err`).
  - Wrapper: the main class's `makeWidget()` returns `Result<Widget>`; `Widget`
    is constructed from `(libHandle, ctx)` and exposes Widget's typed methods,
    each calling the shared `_call(ctx, ...)`.
- **Teardown (per decision 4):**
  - **Sub-wrapper drop (RAII):** calls a new ABI entry, e.g.
    `<lib>_releaseInstance(ctx)`, which on the processing thread drops that ctx's
    event listeners and clears its request providers (so the Nim sub-instance
    becomes collectable; GC frees it). No double-free risk — the wrapper only
    holds the ctx.
  - **`<lib>_shutdown(mainCtx)`:** before stopping threads, drop listeners +
    drain in-flight for the whole library context (extend the existing shutdown
    path). A per-lib-context registry of live sub-ctxs may be used to release
    any still-open subs; keep it keyed by main ctx.

## 4. Work breakdown (suggested order)

> Reprioritized from A1–A5 into dependency order. A0 is a prerequisite that fell
> out of decision 3.

### A0 — gcsafe `new()` (prerequisite)
- `broker_implement.nim`: mark the generated `new()` `{.gcsafe.}` (it already
  uses the immutable-`let` classCtx + atomic instanceCtx + gcsafe
  `setupProviders`). The sub-impl `init` body must then be gcsafe — document it.
- **Risk/decision:** this requires *all* impl `init` bodies to be gcsafe (most
  are trivial field writes → fine). If a real in-process user needs a
  non-gcsafe `init`, add a separate non-gcsafe `newLocal()` and keep `new()`
  gcsafe. Verify the existing tests/examples still compile (their inits are
  gcsafe).
- Verify: `nimble test`, `testApi`, `runHierExamplePy` still green.

### A1 — main-class designation + interface registry + collision errors
- `broker_interface.nim`: when a `BrokerInterface(API)` is declared, register its
  name in a new compile-time registry `gApiInterfaces` (reuse the broker_utils
  registry pattern next to `gInterfaceEvents`). Record per-interface: name, its
  request apiNames, its event names.
- `api_library.nim`: add the **`mainClass: IMain`** field to
  `registerBrokerLibrary` (`parseLibraryConfig`). Validate `IMain` is a
  registered `(API)` interface. The library lifecycle (createContext/shutdown)
  and `setupProviders` bootstrap bind to the main class's ctx.
- Collision: ensure the apiName uniqueness assertion (`api_common.nim`) spans all
  interfaces and the error names the owning interfaces. Add a broker-name
  collision check across interfaces if not already covered.
- Verify: a 2-interface lib compiles; a deliberate cross-interface apiName
  collision is a hard error (add to `test/reject/`).

### A2 — per-interface wrapper class + header (all wrappers)
- For each `(API)` interface, emit a wrapper **class** carrying its typed
  methods. The **main** class keeps `createContext`/`shutdown`/`version` +
  global (main-interface) methods. **Sub** classes get a `(libHandle, ctx)`
  constructor + the release/close path (A4) + their typed methods; **no**
  createContext.
- **Headers/files:** main class in `<lib>.hpp` / `<lib>.py` / `<lib>_rs` /
  `<lib>_go`; each sub-interface in its own file (`<lib>_<Iface>.hpp`, a Python
  class/module, a Rust submodule, a Go file), including/importing the base C ABI
  header. Decide concrete file names per language (mirror the existing single
  wrapper layout).
- Touch: `api_codegen_cbor_{hpp,py,rust,go}.nim` — they currently iterate one
  flat `requestEntries`. Partition entries by owning interface (from the A1
  registry) and emit one class per interface. The C/C++ base header (`.h`) stays
  shared/single.
- Verify: the multi-interface hierlib (see §5) generates per-interface headers;
  each compiles.

### A3 — create-instance request recognition + handshake
- `api_request_broker_cbor.nim`: detect when a request's Ok payload type is a
  registered `(API)` interface (from the A1 registry). For such a request:
  - emit an adapter that calls the provider, takes the returned `IWidget`,
    extracts `widget.brokerCtx`, and CBOR-encodes the `uint32` as the response
    (instead of the normal object/scalar envelope);
  - register a descriptor flavor marking this entry as "returns instance of
    `IWidget`" so wrapper codegen emits `Result<Widget>` and constructs the sub
    class from the decoded ctx.
- Wrapper codegens: for an instance-returning method, decode the `uint32` ctx and
  build the sub-wrapper class object bound to `(libHandle, ctx)`.
- Nim side note: the provider returns `IWidget` (a real ref); the base abstract
  method is `proc makeWidget(...): Future[Result[IWidget, string]]`. Ensure
  `extractResultOk` / payload handling treats a registered interface name as a
  valid payload (special-cased, not a normal object).
- Verify: `mainCtx` → `makeWidget()` returns a working `Widget` in each wrapper;
  calling Widget methods round-trips.

### A4 — wrapper RAII teardown per language
- Add C ABI `<lib>_releaseInstance(ctx)` (in `api_library.nim`): on the
  processing thread, drop that ctx's event listeners + clear its request
  providers (Nim instance becomes collectable). Idempotent.
- Per-language sub-wrapper RAII calling it:
  - **C++:** sub class dtor calls `releaseInstance(ctx_)`; movable, non-copyable
    (or `std::unique_ptr`-friendly). Clean/deterministic.
  - **Rust:** `impl Drop` calls `releaseInstance`.
  - **Go:** `Close()` + `runtime.SetFinalizer` (finalizers non-deterministic →
    `Close()` is the primary path, finalizer is a backstop).
  - **Python:** `close()` / context-manager (`__enter__`/`__exit__`) primary;
    `__del__` as a best-effort backstop (unreliable).
- Verify: creating + dropping a sub-wrapper releases the ctx (a follow-up
  request to that ctx errors / listeners stop). Add per-language assertions.

### A5 — library-context teardown (drain + drop listeners)
- `<lib>_shutdown(mainCtx)`: before stopping threads, drop all event listeners +
  drain/fan-out in-flight requests for the library context (extend the existing
  shutdown sequence in `api_library.nim`; some of this likely exists for the
  courier — audit it). Optionally a per-main-ctx registry of live sub-ctxs to
  release any the foreign side forgot. **Per-lib-context only.**
- Verify: create several sub-instances, don't release them, call shutdown →
  clean teardown (no listener fires afterward, no in-flight orphan, no crash on
  refc + orc).

## 5. Verification strategy

- Extend `examples/ffiapi/hierlib` to **multi-interface**: keep `IHier` (main)
  and add e.g. `IWidget` (a sub-interface) with a main request
  `makeWidget(...) -> Future[Result[IWidget, string]]`. Add the per-language
  consumer steps: create a widget, call its method, drop it (RAII), shutdown.
- Add Nim-level tests: an in-process multi-interface test (main creates a sub,
  calls it, releases it); a reject test for cross-interface apiName collision.
- Gate after each A-step: `nimble test`, `nimble testApi`, `nimble testSugarRejects`,
  and `runHierExample{Py,Cpp,Rust,Go}` (the multi-interface example). The legacy
  `runTypeMapTestLib*` / `runFfiExample*` must stay green (single-interface path
  unchanged).
- Commit per A-step (user directive: commit at each relevant phase). Never push.

## 6. Risks & watch-points

- **A4 per-language RAII** is the riskiest: C++ `unique_ptr`/dtor is clean; Go
  finalizers and Python `__del__` are non-deterministic → make explicit
  `Close()`/context-manager the primary path with finalizers as backstops.
- **A0 gcsafe `new()`** forces gcsafe `init` bodies — fine for trivial inits;
  provide `newLocal()` escape hatch if a real user needs non-gcsafe init.
- **Recognizing interface-typed payloads** must be threaded through 5 codegens
  consistently (the A1 registry is the single source of truth).
- **`extractResultOk` / payload validation** must accept a registered interface
  name as the Ok type (currently expects object/primitive payloads).
- **No FFI instance ownership** (decision 4): do NOT build an instance table in
  FFI; only ctx-keyed listener/provider teardown. The Nim GC owns instances.
- Keep the **single C ABI** — resist per-interface ABI; only the typed wrapper
  surface is partitioned.

## 7. References (anchors for the executing session)

- Memory: `project_oop_brokers.md` (full design history, gotchas — e.g. quote
  gensyms `self`; `macros.error` qualification; plain BrokerInterface =
  single-thread; chronicles leaks `error`).
- `brokers/broker_implement.nim` — `new()`, `bindToContext`, `<Impl>SetupProviders`,
  `close()`; classCtx `let`.
- `brokers/broker_interface.nim` — interface type, abstract methods, facade,
  factory, `registerInterfaceEvents`.
- `brokers/api_library.nim` — `registerBrokerLibrary`, lifecycle, threads
  (`setupProviders(ctx)` call site ~line 987; createContext ~line 1120).
- `brokers/internal/api_request_broker_cbor.nim` — adapters + descriptors +
  naming rule (~358–411).
- `brokers/internal/api_codegen_cbor_{hpp,py,rust,go}.nim` — wrapper classes.
- `brokers/internal/api_schema.nim` — type registry.
- `examples/ffiapi/hierlib/**` — the example to extend; `examples/ffiapi/**`
  (mylib) — reference layout for headers/cmake/cargo/go.
