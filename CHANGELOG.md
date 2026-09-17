# Changelog

All notable changes to **nim-brokers** are documented here. The project follows
[Semantic Versioning](https://semver.org/). Dates are ISO-8601.

## [3.3.0] — 2026-07-14

**Handler body sugar across all lanes: `listenIt` / `onSignalIt` / `provideIt` /
`reprovideIt`, plus a new broker tutorial presentation.** An additive release —
no runtime behavior changes, no breaking changes. Each sugar macro wraps the
existing registration proc, letting a handler be written as an inline block
instead of a separately-declared proc.

### Added — handler body sugar

- **`TypeName.listenIt[(ctx)]: body`** (EventBroker, all lanes) registers a
  listener whose block is the real listener proc body, with the event value
  injected as `it` (nothing injected for `void` event types). Returns `listen`'s
  `Result[<T>Listener, string]`; `await` is allowed and `raises: []` is enforced
  as for a hand-written listener.
- **`TypeName.onSignalIt[(ctx)]: body`** (SignalBroker, all lanes) installs the
  single handler with the signal value injected as `it` (nothing for `void`
  payloads); duplicate-guard and return value are `onSignal`'s.
- **`TypeName.provideIt[(ctx)]: body`** / **`reprovideIt`** (RequestBroker, all
  lanes) register a provider whose block is the real provider proc body with the
  declared signature arg names injected. `provideIt` → `setProvider` (keeps the
  "already set" guard); `reprovideIt` → `replaceProvider` (replace-or-insert).
  Dual-slot brokers also get `provideItNoArgs` / `reprovideItNoArgs`. In sync
  mode the body cannot `await`.
- **`TypeName.provideIt` on MultiRequestBroker** — body sugar over the additive
  `setProvider`, returning its `Result[<T>ProviderHandle, string]` (keep the
  handle for `removeProvider`). No `reprovideIt` (providers are additive, no
  replace verb); each `provideIt` adds a fresh provider.
- **Compile-time fall-through guard** (`providerBody`): a `provideIt` /
  `reprovideIt` body must produce a value on every path (`return ok(...)`/`err(...)`,
  `result = ...`, or a trailing `Result` expression) — otherwise it is a compile
  error rather than a silent `err("")`. A `block` containing `break` and noreturn
  calls (`quit`, `raiseAssert`) are conservatively treated as non-terminal.
- New tests: `test_handler_sugar`, `test_multi_thread_handler_sugar`, and five
  `reject/reject_provideit_*` compile-failure guards. Cookbook recipes added in
  `doc/COOKBOOK.md`; design in `doc/design/BROKER_HANDLER_SUGAR_PLAN.md`.

### Added — docs

- **`doc/BrokerTutorialPrezi.html`** — a standalone slide-deck tutorial walking
  through the broker primitives and their usage.

## [3.2.0] — 2026-07-09

**New `SignalBroker` primitive (fire-and-forget, single-handler, no-reply) across
all lanes, an asynchronous FFI request path (`<lib>_callAsync`), `bind`/`rebind`
provider sugar for class-method providers, and the multi-thread teardown-UAF fix
that greens `--mm:refc` on Windows.** This is a feature release: it adds a fourth
broker shape, a non-blocking FFI call gate with idiomatic async wrappers in all
four foreign languages, and closes the last Windows/refc sanitizer gap. No
breaking changes to the existing single-thread, multi-thread, or FFI surfaces.

### Added — `SignalBroker` / `SignalBroker(mt)` / `SignalBroker(API)`

- **A new one-way, single-handler broker** fusing EventBroker's dispatch shape
  (sync call site + `asyncSpawn`, no reply path) with RequestBroker's
  single-registry ownership and a `Result[void, string]` acceptance check.
  Declared with an `object` / `ref` / POD / `void` payload. One handler is
  installed via `TypeName.onSignal(handler)` (duplicate-guarded, mirrors
  `setProvider`); producers call `TypeName.signal(...)` — a **plain non-async
  proc** returning `Result[void, string]`. Value form, inline-field overloads
  (like `emit`), and a `void` pulse (`TypeName.signal()`) are all generated.
  - `ok()` means **accepted** (best-effort snapshot: a handler exists and the
    queue had room), never "handled". `err` is definitely-not-delivered:
    `"no signal handler installed"` or `"queue full"`. Handler exceptions are
    swallowed with a chronicles warn — for delivery confirmation use a
    RequestBroker with a `void` response.
  - `dropSignalHandler()` is async `Future[void]` (uniform with `dropListener`,
    suspension-free body). Mock/replace trio: `replaceSignalHandler` /
    `getCurrentSignalHandler` / `withMockSignalHandler` (MT variants are
    owning-thread only).
- **Single-thread lane** (`brokers/signal_broker.nim`) and **multi-thread lane**
  (`brokers/internal/mt_signal_broker.nim`): the MT lane reuses EventBroker(mt)'s
  global refcounted slab + per-bucket Vyukov ring transport and
  RequestBroker(mt)'s single-registry ownership. Same-thread `signal` → direct
  `asyncSpawn`; cross-thread → marshal payload → enqueue → wake. Lock-free
  `signal()` fast-fail via a per-type `Atomic[int]` handler-present counter
  (`signalHandlerPresent`). The owning thread allocs the ring; `dropSignalHandler`
  closes it and the poll fn hands it to the per-thread pending-free registry,
  freed at `teardownBrokerThread`.
- **FFI `SignalBroker(API)` lane** (`brokers/internal/api_signal_broker_cbor.nim`)
  rides `<lib>_call` on a **slot-free, one-way** path: the payload is enqueued
  onto the courier ring with a sentinel (no response slot, no round trip) and the
  call returns immediately. Both failure modes resolve on the caller's thread — a
  lock-free `signalHandlerPresent` load → `ApiStatusProviderErr` (-10) when no
  handler, or a courier-ring-full → `ApiStatusAgain` (-6); accepted →
  `ApiStatusOk` (0). `<lib>_callAsync` **rejects** a signal name with
  `ApiStatusOneWay` (-13). A CBOR decode failure in the adapter is logged, not
  returned.
- **Discovery + wrappers.** Signals surface as a top-level `signals` list
  (`ApiSignalInfo`, the inverse of `events`) in `_listApis` / `_getSchema` / the
  CDDL and in the generated C header. Each foreign wrapper emits a typed one-way
  method with **no async variant** — C++ `Result<void>`, Python `-> None`
  (raising), Rust `Result<(), String>`, Go `error`. Full four-language parity is
  gated by the typemappingtestlib signal matrix.
- **`BrokerInterface` / `BrokerImplement` support** for `SignalBroker(API)` on
  both the main interface and sub-interfaces, including sub-interface FFI signal
  routing.
- New tests: `test_signal_broker`, `test_multi_thread_signal_broker`,
  `test_api_signal_broker`, `test_broker_interface_signal`,
  `perf_test_multi_thread_signal_broker`, four `reject/reject_signal_*` guards
  (bad mode / bad shape / no handler / duplicate handler), plus ASan/TSan tasks
  for the MT and FFI signal lanes.

### Added — asynchronous FFI request path (`<lib>_callAsync`)

- **A non-blocking request gate** alongside the blocking `<lib>_call`. `_callAsync`
  submits a request and returns immediately with an `ApiStatus`; the response is
  delivered later through the async response callback. Backed by a configurable
  async window (in-flight cap) with an **EAGAIN-friendly contract** —
  `ApiStatusAgain` (-6) when the window is saturated — plus a **per-request
  timeout**.
- **Idiomatic async wrappers in every foreign language**, each mapping to the
  host's native async idiom rather than a raw callback:
  - **C++** — a `std::future`-returning sibling for each async method.
  - **Rust** — a typed `AsyncError` + `std::result::Result`, no `tokio`
    dependency, with a per-call timeout exposed on the generated `_async` method.
  - **Go** — `context.Context`-aware methods with semaphore backpressure.
  - **Python** — `async def` methods over the callback bridge.
- Response status codes are single-sourced, and dispatch-result encoding is shared
  across the courier handlers. New `test_api_callAsync` exercises the full path.

### Added — `bind` / `rebind` provider sugar (#42, #43)

- **Class-method providers can now be wired with `bind` / `rebind` sugar** instead
  of hand-writing the closure that captures `self`. Simplifies registering a
  `BrokerImplement` method as a RequestBroker provider.

### Fixed — multi-thread teardown use-after-free (#38, #39)

- **Ordered per-thread teardown + close-safe shared signals** eliminate the
  Windows/`--mm:refc` teardown UAF (a race between broker-signal teardown,
  setProvider registration seqs, and refc `deallocOsPages`). The fix pairs a
  `BrokerSignalShared` refcount with `teardownBrokerThread` ordering and is
  regression-gated by the new `nimble testAllocRace` task on the Windows CI cells.
- **The `skipRefcOnWindows` carve-out is removed entirely** — Windows + refc is now
  CI-green across the parity matrix. See `doc/LIMITATION.md` §2.2 and
  `doc/design/TEARDOWN_UAF_FINDINGS.md` for the mechanism and the remaining
  app-level caveat.
- Sanitizer matrix (ASan/LSan/TSan) is green on Windows and Linux; residual
  benign reports (ORC `registerCycle` roots buffer, `setProvider` registration
  seqs, event-poll bookkeeping seq) are suppressed via `tools/sanitizers/lsan.supp`.

### Changed — performance (#35)

- **The default-context RequestBroker forwarder returns the inner `Future`
  directly** instead of allocating a wrapper Future — one fewer allocation per
  default-context request.
- New in-process and FFI-overhead perf harnesses (`test/ffibench/perf_inproc.nim`,
  `perf_overhead.nim`, `perf_phases.nim`) plus a `perftestInproc` task measure
  broker dispatch overhead vs. a direct call and serial-vs-pipelined request
  throughput.

### Documentation

- New **broker cookbook** and **USAGEGUIDE**, README refreshed with a SignalBroker
  section and `bind` sugar, FFI prezi updated to CBOR-only, and the torpedo
  `DESIGN.md` refreshed.

## [3.1.4] — 2026-06-19

**`BrokerImplement` constructors gain result-shape parity with `new` and adopt
the ambient global broker context.** The generated `create` /
`createUnderContext` wrappers now mirror whatever shape the implementation's
`new` returns, and `create` connects its instance to the current global scope
instead of an isolated per-class context.

### Changed — `BrokerImplement` `create` / `createUnderContext`

- **`create` / `createUnderContext` mirror the `new` constructor's return
  shape** across all four forms: `new(...): T` → `create(): T`,
  `new(...): Future[T] {.async.}` → `create(): Future[T] {.async.}`,
  `new(...): Result[T, string]` → `create(): Result[T, string]`, and
  `new(...): Future[Result[T, string]]` → `Future[Result[T, string]] {.async.}`.
  The wrapper unwraps `new`'s result (`await` / `valueOr`) into a bare `self: T`,
  binds `brokerCtx`, runs the optional `PostInit` hook, then wires providers via
  the unchanged `<Impl>SetupProviders` (which never sees the Future/Result
  wrapper). The sync-bare form is byte-identical to the legacy codegen, so
  existing implementations are unaffected. Also fixes a chronos/`parseStmt`
  interaction — an `{.async.}` proc carrying a `typedesc` param is implicitly
  generic, and synthetic line info crashed the async transform; the async
  wrappers are now re-stamped with a real source location (`copyLineInfoRec`).
- **`create` adopts the ambient global `classCtx`.** It previously minted a
  per-class `classCtx` (`<Impl>BrokerClassCtx` via `newClassCtx()`), disconnected
  from the thread-global scope. It now allocates its per-instance context with
  `newInstanceCtx(globalBrokerContext())` — the `classCtx` is read from the
  current `globalBrokerContext()` at call time, so a `create`'d instance shares
  the global scope of the bare brokers (or the locked test context), while
  `instanceCtx` stays unique via `newInstanceCtx`'s process-global counter. The
  per-class `<Impl>BrokerClassCtx` / `<Impl>BrokerInstCounter` module state is
  dropped. `createUnderContext(ctx, …)` is unchanged for explicit/foreign scopes.
- New `test/test_broker_ctor_shapes.nim` covers all four constructor shapes plus
  `createUnderContext` and the locked-scope adoption behavior; registered in the
  `test` task.

## [3.1.3] — 2026-06-18

**Uniform EventBroker call shape across all lanes, plus a batch of FFI
wrapper type-mapping fixes (alias / `seq[byte]` / proc-sugar payloads) and
courier-ring drop visibility.** `emit` is now sync `void` everywhere and
`dropListener` / `dropAllListeners` are async `Future[void]` everywhere, so the
public shape of an EventBroker no longer changes when its tag flips between
*(none)* / `(mt)` / `(API)` and the same source compiles in any lane. The FFI
fixes were surfaced while generating wrappers for the Logos Delivery library;
they preserve meaningful alias names and fix several proc-sugar payload shapes
across all four foreign wrappers.

### Changed — EventBroker `emit` / `drop*` shapes

- **`emit` is now sync `void` in the multi-thread and API lanes** (it already
  was in the single-thread lane). The MT `emitImpl` is a plain
  `{.gcsafe, raises: [].}` proc; the public `emit` and inline field-constructor
  overloads call it directly. The cross-thread marshal + ring enqueue still
  happen synchronously before `emit` returns — no work is deferred. **Migration:
  drop `await` / `waitFor` from every `(mt)` / `(API)` emit call site**
  (`await X.emit(a)` → `X.emit(a)`).
- **`dropListener` / `dropAllListeners` are now async `Future[void]` in the
  multi-thread and API lanes** (they already were in the single-thread lane),
  for cross-lane shape parity. The MT/API drop bodies stay suspension-free, so
  the returned Future completes eagerly — a discarded Future (e.g. from sync FFI
  teardown) still clears listeners and fires the cleanup hook.
  Non-discardable in every lane. **Migration: `await` your `(mt)` / `(API)` drop
  calls** (or `discard` / `waitFor` in sync / `{.thread.}` contexts).
- `clearProvider` / `clearProviders` are unchanged — sync in every lane.
- Guiding principle: the public shape follows whether the op *actually
  suspends*. `emit` never awaits listener completion in any lane → sync. Drop on
  the single-thread lane genuinely awaits in-flight listener cancellation →
  async, and the other lanes adopt that shape.
- No FFI ABI or foreign-wrapper change — neither `emit` nor `drop*` is exposed
  on the C ABI (verified against the C++/Python/Rust/Go parity matrices).

### Fixed — FFI wrapper type mapping (alias / `seq[byte]` / proc-sugar payloads)

- **Registered type aliases / distincts now keep their name throughout every
  wrapper.** Object and event-payload fields and unpacked event-callback params
  typed with a registered alias (`channelId: ChannelId`, `timestamp: Timestamp`)
  were flattened to the resolved primitive (`std::string`, `int64_t`); the field
  and param mappers (`nimTypeToCppType` / `…PyHint` / `…RustHint` /
  `…GoCborHint`) now return the alias name when its underlying maps, so C++,
  Python, Rust, and Go all see `ChannelId` / `Timestamp` rather than the bare
  primitive. The C++ event-callback param mapper got the same fix
  (Rust/Go already went through the general field mapper).
- **Pure type aliases are now resolved in wrapper type discovery.** Aliases like
  `type ContentTopic = string` / `Timestamp = int64` were dropped because
  registration keyed off `getTypeInst` (which echoes a pure alias's own name);
  discovery now uses `getTypeImpl` to chain through alias-of-alias to the base
  symbol. Also fixes alias-typed fields inside `Option[T]` / `seq[T]` and
  structurally-identical `array[N, byte]` aliases (captured as-written so
  `WakuMessageHash` and `Curve25519Key` no longer collide), and stops
  `resolveActualSym` mis-unwrapping a non-`typedesc` `array[…]` bracket.
- **`seq[byte]` maps to an ergonomic `Bytes` vector in the C++ wrapper** — a
  per-library `struct Bytes : std::vector<uint8_t>` whose `json_type_traits`
  force a CBOR byte string (major type 2), matching how Nim's
  `cbor_serialization` decodes it. Previously C++ emitted a jsoncons-specific
  `byte_string` (correct on the wire, unergonomic in the public type).
- **proc-sugar request brokers now emit the right response payload type in
  every wrapper.** A verb-named broker registers its verb as a synthetic
  distinct alias of the payload; codegen used to surface that synthetic name
  (`Result<Send>`, `Result<StartDiscv5>`) instead of the real payload. Fixed for
  scalar alias/distinct payloads (`Result<RequestId>`), bare primitives
  (`Result<bool>`), `seq[...]` / `array[N,T]` containers, and standalone
  registered objects (whose return type is now scanned and registered, not
  dropped as "not emittable").

### Added on FFI layer

- **`registerBrokerLibrary` `version:` accepts a `const` identifier**, not just
  a string literal — so a build-time version (`-d:git_version=…` strdefine)
  works. The generated `<lib>_version()` binds the version expression to a
  string const in the caller's module and returns its `.cstring`; foreign
  wrappers expose version only via the runtime `_version()` call and are
  unchanged.
- **Outbound events dropped on a full courier ring are now logged.** The CBOR
  event courier is a bounded fire-and-forget ring (256 → 1024); on overflow
  `tryEnqueue` drops by design, but the drop was silent. A throttled `warn` now
  fires at the generated emit drop site — first drop always logs, then a
  geometric count backoff (10, 100, 1000 …) plus a 5 s periodic floor so a
  steady stall keeps reporting without flooding the producer hot path.

## [3.1.2] — 2026-06-10

**`Table[K, V]` associative-container support across the full FFI surface with
complete scalar-key coverage in all four wrappers, broker method tunneling +
first-class provider mocking, natural `proc new` constructor ergonomics, and a
chronos dispatcher fd-leak fix for the createContext/shutdown cycle.**

### Added — FFI associative containers

- **`Table[K, V]` / `OrderedTable[K, V]` support through the CBOR FFI surface,
  with no `cbor_serialization` dependency change.** The Table codec lives in
  the brokers package (`brokers/internal/api_cbor_tables.nim`) and rides the
  library's *public* reader/writer API rather than the patched
  `cbor_serialization/std/tables` binding, so the dependency pin stays at its
  upstream release. Keys travel on the wire as CBOR text strings (the codec
  writer only emits string map keys); each wrapper converts text ⇄ typed key
  in generated code. Recognition is wired through the compile-time type schema
  and the external-type resolver (`api_schema.nim`, `api_type_resolver.nim`):
  `ApiFieldDef` gains `isTable` / `tableKeyType` / `tableValueType`, bracket-
  depth-aware `K, V` splitting keeps a composite value type's own commas
  intact, and `validateTableKey` rejects unsupported keys (plain platform-width
  `int`/`uint`, `bool`, `float`, composites) at compile time with a clear
  error. `nimTypeToCddl` emits `{* tstr => <V>}` for the discovery/CDDL schema.
- **Full scalar Table-key coverage in all four wrappers** — `string`,
  `int8..64`, `char`, `enum` (ordinal on the wire), and `distinct`-of-scalar
  keys round-trip through Python, C++, Rust, and Go:
  - **Python** (`cbor2`) — full coverage via `pyKeyClass` helpers in
    `pyEncodeExpr` / `pyDecodeExpr` (`int(_k)`, `Priority(int(_k))`, string
    passthrough) → `Dict[K, V]`.
  - **Rust** (`ciborium`/`serde`) — a generic `cbor_strkey_map` serde adapter
    (emitted only when a struct has a non-string-keyed Table field) converts
    the text-keyed wire map ⇄ typed-key `HashMap` via `Display`/`FromStr` on
    generated enums; string/char keys map to `String` and skip the adapter.
  - **Go** (`fxamacker/cbor`) — generated `MarshalCBOR`/`UnmarshalCBOR`
    round-trip through a string-keyed wire struct, converting keys via
    `strconv` (int/enum/distinct-of-int through `int64`) → `map[K]V`.
  - **C++** (`jsoncons`) — a string-keyed `<Name>__wire` mirror plus a custom
    `json_type_traits<Json, Name>` that delegates field (de)serialisation to
    the wire struct and converts only the map keys (`char` via first byte,
    int/enum/distinct via `std::stoll`/`std::to_string`) →
    `std::unordered_map<K, V>`.
  Verified orc + refc against the **unpatched** dependency:
  `runTypeMapTestLib{Py,Cpp,Rust,Go}` 133/133 each;
  `test/test_api_table_codec.nim` round-trips 9 Table shapes and is wired into
  the `testApi` codec list.

### Added — Broker interfaces (OOP brokers)

- **Interface request methods now tunnel through the broker.** The public
  request entry point generated by `BrokerInterface` is a plain proc that
  delegates to `<Broker>.request(self.brokerCtx, …)` instead of a `{.base.}`
  pure-virtual method. `BrokerImplement` emits the user's method body as a
  private `<verb>Impl` proc and points the per-instance provider closure at it.
  Effect: both `instance.method(…)` and `IFace(instance).method(…)` route
  through the broker dispatch path — so a provider swap (mock) is honored on
  direct calls (previously bypassed), MT cross-thread calls go through the
  channel tunnel with thread affinity preserved, and the raw body runs only
  inside the provider closure on the owning thread.
- **First-class provider introspection + mocking** on `RequestBroker`, both
  single-thread and MT, per context and per slot
  (`request_broker.nim`, `mt_request_broker.nim`):
  - `getCurrentProvider(T, ctx)` / `getCurrentProviderNoArgs(T, ctx)` →
    `Option[provider]` (distinct names because return-type-only overloads are
    illegal; both slots can coexist on one broker).
  - `replaceProvider(T, ctx, handler)` — replace-or-insert; never errors on an
    existing entry, unlike `setProvider`.
  - `withMockProvider(T, ctx, mock): body` — scoped, exception-safe
    save/restore template.
  MT variants read the per-thread threadvar slot and are therefore
  **owning-thread only** (documented); cross-thread introspection is
  unsupported (the shared bucket holds a ring, not the closure).
- **Natural `proc new` constructor ergonomics.** The magic-self
  `proc init(...)` constructor is replaced by a user-authored
  `proc new(T: typedesc[Impl], …): Impl` that builds and returns a **bare**
  instance. The macro wraps it with two decorators: `Impl.create(args…)`
  (allocates a fresh instance context, then decorates) and
  `Impl.createUnderContext(ctx, args…)` (adopts an external context; renames
  the old `bindToContext`; used by the FFI lane and sub-instance factories).
  An optional `proc init(self: Impl)` post-context hook runs after `brokerCtx`
  is bound and before providers are wired, for ctor logic deriving per-instance
  state from `self.brokerCtx`. A zero-arg default `new` is synthesized when
  omitted.

### Fixed — FFI

- **chronos dispatcher selector fd leaked per createContext/shutdown cycle.**
  chronos 4.2.2 has no `PDispatcher` teardown and its `SelectorImpl` has no
  `=destroy`, so each broker thread's selector OS fd (kqueue on macOS, epoll on
  Linux) was never closed. The API library spawns a processing + delivery
  thread per `_createContext` and joins them per `_shutdown`, so every context
  lifecycle leaked **2 fds** regardless of `--mm:refc` vs `--mm:orc` (a missing
  destructor, not a GC-mode issue). New `closeThreadDispatcherSelector()` in
  `mt_broker_common.nim` (chronos public surface only) is called as the last
  action of both generated broker thread procs, after the dispatch loop has
  exited. Made portable to the Windows IOCP branch (`closeHandle` on the IOCP
  `HANDLE`, forward-declared to avoid a `chronos/osdefs` import that
  destabilised the Windows + Nim 2.2.4 + refc + release MT build). Regression
  test `test/test_api_library_init.nim` runs 20 create/shutdown cycles and
  asserts no fd growth (verified delta=40 without the fix, delta=0 with it, on
  orc + refc). The Nim 2.2.4 + Windows leg skips the assertion — a known
  Nim-runtime `joinThread` HANDLE leak (2/cycle) fixed in Nim 2.2.10.
- **`eventCourier` leaked on the delivery-thread-not-ready `_createContext`
  failure path.** That cleanup branch freed the call courier but never the
  event courier (unlike the two sibling failure paths), leaking a
  `CborEventCourier` + its 256-slot ring + a `Lock` on the shared heap. Added
  the missing `drainAndFree(arg.eventCourier)`.
- **C++ sub-instance constructor `noexcept` mismatch.** The CBOR C++ wrapper
  emitted the sub-instance constructor *declaration* without `noexcept` while
  both definitions used it, causing an "exception specification … does not
  match" error on any `BrokerInterface` returning a sub-instance. All three
  sites now agree.

### Tests

- `test/test_api_table_codec.nim` — 9-shape Table CBOR round-trip against the
  upstream (unpatched) dependency.
- `test/test_broker_method_tunneling.nim` — mock honored on direct + base-typed
  calls, per-ctx isolation, capture/replace/restore, `withMockProvider`,
  cross-thread instance-method tunneling.
- `test/test_mt_provider_mock.nim` — MT provider mocking on the owning thread.
- `runTypeMapTestLib{Py,Cpp,Rust,Go}` gain `test_map_result_all_key_flavors`
  (int32/char/enum/distinct keys), `map_param_roundtrip`, and `map_event`.

### Changed

- Design/plan docs relocated under `doc/design/` (`ASSOC_CONTAINERS_PLAN.md`,
  `ASSOC_CONTAINERS_IMPL_PLAN.md`) alongside the existing `HIERARCHICAL_*` /
  `PLAN_*` / `CBOR_*` docs. `doc/OOP_Brokers.md` updated for tunneling, the
  `proc new` + `create`/`createUnderContext` surface, and a new
  "Testing — mocking providers" section.

## [3.1.1] — 2026-06-02

**Flexible MT payload sizing, dynamic CBOR courier growth, `void`-"payload"
for RequestBroker's proc-syntax-sugar, pure-Nim persistence example.**

### Added — Multi-thread brokers

- **Flexible MT payload sizing — `uint32` size fields + automatic
  heap-spill** (`mt_queue.nim`, `mt_codec.nim`, `mt_config.nim`,
  `mt_event_broker.nim`, `mt_request_broker.nim`). `CellHeader.payloadSize`
  and `ResponseSlotHeader.payloadSize` widened from `uint16` to `uint32`
  (the previous 64 KiB ceiling silently wrapped — the `largePayload` preset
  stored `payloadSize = 0`). When a marshaled payload exceeds the fixed
  slab cell, the producer spills the bytes to an `allocShared0` buffer
  referenced via new `CellHeader.overflow` / `overflowLen` fields
  (symmetric on `ResponseSlotHeader`). The MPSC ring still carries the
  `uint32` cell index unchanged. Spill is always-on, gated only by a new
  `maxDynamicPayloadBytes` kwarg (default `high(uint32)`) as an OOM/DoS
  backstop. New `mtMarshalSizeValue` + per-type `<T>MtMarshalSize`
  companions size the spill buffer in one pass. The common fits-the-cell
  path is unchanged and allocator-free. Verified via
  `test/test_mt_large_payload.nim` (1.5 MiB inline + spill for
  event/request/response + over-ceiling drop) green on orc/refc × debug/
  release; ASAN clean.

### Added — RequestBroker

- **`void` payload in proc-sugar form** across single-thread, MT, and API
  brokers. `RequestBroker: proc f(...): Future[Result[void, string]]` (and its `sync`
  variant) now lowers correctly through every dispatch path: the MT binary
  response codec guards the four payload-value touches
  (`marshalResp` / `unmarshalResp` / `marshalRespSize` / same-thread
  nil-check) with `when (payloadType is void)`, and the API/CBOR adapter
  bridges the `void` Result to a `CborUnit` envelope (bit-for-bit
  identical to the legacy `type X = void` wire form).

### Added — Examples

- **Pure-Nim persistence example** (`examples/persistence/nim_example/`).
  Replicates the three C++ scenarios (two contexts, mixed backends,
  concurrent load) using broker interfaces directly — single-thread
  chronos async, no FFI, no CBOR. Demonstrates the factory pattern:
  `PersistenceFacade` registers a zero-arg `provideFactory` at module
  init; the example uses `IPersistence.create()` and never imports any
  concrete impl type. New `nimble runPersistenceExampleNim` task
  (honours `MM=orc|refc`).

### Fixed — FFI

- **Dynamic growth for `CborCallRing` / `CborEventRing` via append-only
  slot segments** (`api_cbor_courier.nim`, `api_cbor_event_courier.nim`,
  `api_request_broker_cbor.nim`). Resolves #21. On response-slot-pool
  exhaustion the pool now grows by *appending* a new segment rather than
  reallocating one array — relocating a slot whose `Lock`/`Cond` a blocked
  `_call` is waiting on would be a use-after-free. Append-only segments
  keep every published slot address stable. Growth coordinates the slot
  pool and the ring together under `ring.lock`, doubling up to a
  `4 * origSlotCount` ceiling. A global slot index maps to its owning
  segment via `slotAt`; claims scan the published segments lock-free.
  Covered by new `test/test_api_courier_growth.nim`.
- **Hardened CBOR courier growth paths against `allocShared0` OOM**.
  `growRingLocked` now returns `bool` and leaves the ring untouched on
  alloc failure. `claimSlot` nil-checks the new slot segment (release
  lock + return `-1`, the refusal contract) and grows the ring *before*
  committing any pool state — on ring OOM it rolls back the fresh segment
  (deinit locks/conds, `deallocShared`) so `slotCount` / `segs` / `nSegs`
  stay consistent. Event-courier path nil-checks the grown ring buffer
  and falls back to the drop contract on OOM instead of nil-deref. Stale
  `mt_queue` cell-layout comment corrected — payload now starts at
  `sizeof(CellHeader)`, not offset 16.

### Fixed — RequestBroker

- **Single-thread `sync` keyed-overload ordering bug** uncovered by the
  proc-sugar work (`request_broker.nim`). Pre-existing — surfaced when
  exercising sync sugar via `test/test_request_broker_sync_void.nim`.

### Changed

- **Design docs relocated** to `doc/design/` (`Event_Dispatch_Options.md`,
  `HIERARCHICAL_BROKERS_PLAN.md`, `HIERARCHICAL_BROKERS_DEFERRED.md`,
  `HIERARCHICAL_BROKERS_REDUCED_A_PLAN.md`,
  `PLAN_global_subscount_teardown_fix.md`). New
  `doc/FLEXIBLE_MT_DISPATCH_PLAN.md` documents the spill design.

### Tests

- `test/test_mt_large_payload.nim` — 1.5 MiB inline + spill matrix for
  event/request/response + over-ceiling drop.
- `test/test_api_courier_growth.nim` — pool + ring growth coverage.
- `test/test_request_broker_sync_void.nim` — sync `void`-payload
  proc-sugar regression suite.
- New `void`-payload cases in `test/test_request_broker.nim` and
  `test/test_multi_thread_request_broker.nim`.

## [3.1.0] — 2026-05-28

**Hierarchical / OOP brokers — `BrokerInterface`, `BrokerImplement`,
RequestBroker proc-sugar, multi-interface FFI with sub-instance routing.**

### Added — OOP broker layer

- **`BrokerInterface` macro** (`brokers/broker_interface.nim`). Declares an
  abstract interface (`ref object of RootObj`) with typed request methods
  (abstract `{.base, async:(raises:[]), gcsafe.}` methods) and event facades
  (`emit`/`listen`/`dropListener` templates forwarding via `self.brokerCtx`).
  Two forms: `BrokerInterface IFace:` (in-process only) and
  `BrokerInterface(API, IFace):` (generates FFI-capable `(API)` sub-brokers).
- **`BrokerImplement` macro** (`brokers/broker_implement.nim`). Attaches
  concrete behavior to an interface: `BrokerImplement Impl of IFace:` with
  optional `proc init(...)` and raw `method` overrides. Generates `Impl.new()`,
  `setupProviders` (closure-captured `self` per request), idempotent `close()`
  (clears providers + drops all event listeners, breaking refc cycles).
  `bindToContext(ctx, ...)` adopts an external `BrokerContext` (used by FFI
  processing thread).
- **Factory / dependency-injection** on every `BrokerInterface`: typed
  `IFace.provideFactory(f)` (last-wins) + `IFace.create(...)`. Consumer
  depends only on the interface module; implementer calls `provideFactory`;
  composition root wires both.
- **`RequestBroker.isProvided`** — query whether a provider is registered for
  a given context.

### Added — RequestBroker proc-sugar

- **Proc-style request declaration** across single-thread, MT, and API
  brokers. Lowercase verb procs (`proc getHealth(...)`) pair with a
  capitalized broker name (`GetHealth`). POD form (bare scalar/string
  return) and object form (explicit `type GetHealth = object`) both
  supported. Two-slot naming: single signature → bare apiName; both
  zero-arg + arg-based → bare + `<name>Arg`. Legacy `signature*` syntax
  unchanged.

### Added — Multi-interface FFI (sub-instances)

- **`mainClass: IMain` in `registerBrokerLibrary`** designates the library's
  primary interface. Only the main class exposes `_createContext` /
  `_shutdown`. Additional `BrokerInterface(API)` interfaces become
  sub-interface wrapper classes.
- **`<lib>_releaseInstance(ctx)`** C-ABI entry point for sub-instance
  teardown. Clears providers and drops all listeners for the sub-instance
  context on the processing thread.
- **Sub-instance routing via `BrokerContext` layout**: low 16 bits = classCtx
  (library identity), high 16 bits = instanceCtx. `_call(subCtx)` recovers
  the library courier by classCtx masking; the full ctx routes to the
  sub-instance's provider. `newInstanceCtx(parentCtx)` allocates a fresh
  instanceCtx sharing the parent's classCtx.
- **Sub-instance events**: emit-side courier lookup is classCtx-masked so
  sub-instance `EventBroker(API)` events reach foreign subscribers.
  Per-classCtx listener installer registry ensures new sub-instances get
  event-courier wiring automatically.
- **Per-interface wrapper classes** in all four foreign-language codegens:
  - **C++**: sub-interface class with typed methods, `close()` →
    `releaseInstance`, `~Sub()` destructor. Event-bearing subs returned as
    `Result<std::unique_ptr<Sub>>` (non-movable due to EventDispatcher);
    event-free subs returned by value.
  - **Rust**: `pub struct Sub { ctx }` + `impl Drop` → `releaseInstance`,
    typed methods, `close()`.
  - **Go**: `type Sub struct { ctx, mu }` + `Close()` +
    `runtime.SetFinalizer` → `releaseInstance`, typed methods.
  - **Python**: sub-class with `(ctx)` ctor, typed methods, context-manager
    support, `close()` → `releaseInstance`.

### Changed

- **`BrokerContext` layout split** (`broker_context.nim`): classCtx (low 16)
  + instanceCtx (high 16). `DefaultBrokerContext = makeBrokerContext(1, 0)`.
  `NewBrokerContext()` allocates a fresh classCtx with instanceCtx 0.
  Backward-compatible — flat brokers operate with instanceCtx = 0.
- **`close()` clears event listeners** via compile-time interface → events
  registry (broker_utils). Each `BrokerImplement` close now calls
  `EventType.dropAllListeners(self.brokerCtx)` for every event declared in
  the interface.

### Fixed

- **FFI event subs-count teardown**: decrement shared per-event atomic
  counter on context teardown instead of resetting to zero (could zero out
  other contexts' subscriptions).

### CI / testing

- **Sanitizer coverage expanded**: UBSan-in-ASan, separate TSan, Linux
  ASan+LSan modes added to CI.
- `hierlib` and `persistence` OOP examples added to CI matrix
  (`runHierExample{Py,Cpp,Rust,Go}`, `runPersistenceExampleCpp`).
- New test files: `test_request_broker_sugar.nim`, `test_broker_oop.nim`,
  `test_broker_lifecycle.nim` (wired into `nimble test`);
  `test_broker_interface_api.nim`, `test_broker_interface_mt.nim` (wired into
  `nimble testApi`); `test/reject/*.nim` compile-fail tests (wired into
  `nimble testSugarRejects`).
- Broker lifecycle test (`test_broker_lifecycle.nim`): skip broadened to
  cover Nim 2.2.4 + refc + release on Linux/Windows, and refc + Windows
  debug.

### Examples

- **`examples/ffiapi/hierlib`** — single-interface OOP FFI example
  (`BrokerInterface(API)` + `BrokerImplement` + `bindToContext` +
  `registerBrokerLibrary`) with C++, Python, Rust, and Go consumers.
- **`examples/persistence`** — multi-interface example
  (`IPersistence` main + `IBackend` sub-interface) demonstrating
  sub-instance creation, per-instance event routing, concurrent multi-context
  scenarios, and targeted sub-instance teardown. C++ consumer with
  Rust/Python/Go sub-instance events deferred.

### Docs

- `doc/HIERARCHICAL_BROKERS_PLAN.md` — full design document for the OOP
  broker layer.
- Updated README and AGENTS.md with OOP broker documentation.

## [3.0.0] — 2026-05-22

**Native C-ABI FFI strategy retired — CBOR is now the only transport. The
Nim ↔ FFI wire path is rebuilt on per-context CBOR couriers.**

> :rotating_light: **Breaking vs. 2.x.** The `native` typed-C export ABI is
> gone. Libraries that compiled against the native per-type C structs
> (`*CItem` / `*CResult`, per-result free helpers, pointer+count batch
> layout) no longer build. There is no migration shim — port to the CBOR
> surface (which has been the recommended strategy since 1.0.0). The
> **public wrapper surface for C++ / Rust / Go / Python is unchanged**: those
> wrappers already rode the CBOR ABI, so consumer code that used the typed
> wrappers needs no source changes — only a rebuild.

### Removed (breaking)

- **Native C-ABI codegen deleted.** `api_codegen_{c,cpp,python,rust,go,nim}.nim`,
  `api_event_broker.nim`, `api_request_broker.nim`, `api_type.nim`, and
  `api_ffi_mode.nim` are removed. `brokers/api_library.nim` shrinks by
  ~1080 lines; the branch nets ~12.9k deletions across 104 files.
- **FFI build flags collapsed to a single switch.** Only `-d:BrokerFfiApi`
  remains and it always selects CBOR. `-d:BrokerFfiApiNative` is now a hard
  `{.fatal.}` compile error; `-d:BrokerFfiApiCBOR` was a transitional alias
  and has been removed (bare `-d:BrokerFfiApi` covers it).
- The `RequestBroker(API)` / `EventBroker(API)` macro dispatchers no longer
  emit a native branch; the deprecated `ApiType` annotation and its dead
  array-size-const pipework (`gArraySizeConsts`, `registerArraySizeConst`)
  are gone — plain Nim `object` types are auto-resolved.

### Changed — Nim ↔ FFI transport rebuilt on CBOR couriers

- **Request path:** the stale `AsyncChannel` is replaced by a per-context
  CBOR request courier (`api_cbor_courier.nim`) — a POD MPSC ring plus a
  per-call response slot guarded by `Lock`+`Cond`. The cross-thread cost of
  an FFI request is one ring enqueue + one signal
  (`claimSlot → tryEnqueue → fireBrokerSignal → poller → asyncSpawn →
  handler → completeSlot`), with no typed marshalling overhead since
  `.request()` runs same-thread on the processing thread.
- **Event path:** a per-context event courier (`api_cbor_event_courier.nim`)
  drives a three-lane dispatch — (1) same-thread Nim listeners via direct
  `asyncSpawn`, (2) cross-thread Nim listeners via the MT typed-slab path,
  (3) foreign callbacks via the new courier ring + delivery-thread fan-out.
  A per-bucket atomic `foreignSubsCount`, read lock-free on the emit thread,
  short-circuits the entire FFI lane when no foreign subscriber is
  registered (zero allocations, zero encode, zero ring touch). When a
  foreign subscriber exists, emit costs **one CBOR encode regardless of
  subscriber count**. See `doc/CBOR_Round2_PartD_EventCourier.md` and
  `doc/bench_baseline.md` § "Event dispatch — Part D".

### Added

- **`EventBroker(API)` / `RequestBroker(API)` accept the full MT capacity /
  preset kwargs** — `queueDepth`, `slabCapacity`, `maxPayloadBytes`,
  `responseSlots`, `maxResponseBytes`, `freeListShards`, and `preset = <name>`
  — since the API broker rides the multi-thread lane internally and there is
  no second transport to size separately. Omitting kwargs yields
  `defaultMtEvtCfg()` / `defaultMtReqCfg()`. Previously these were rejected.

### Type support

- With native gone, the **CBOR surface is now the sole carrier of the full
  type matrix**: type auto-resolution emits idiomatic typed representations
  in every wrapper (C++ struct + jsoncons traits, Python `@dataclass`, Rust
  serde struct, Go struct with cbor tags). `seq[Object]` batches cross as a
  single nested CBOR array decoded in the Nim adapter before the provider is
  invoked — no per-type C struct, no pointer+count layout.

### Platform support

- **Full Windows support verified for both `refc` and `orc`.** The historical
  `skipRefcOnWindows` / `memoryManagerMatrix` Windows carve-outs are disabled
  so the entire wrapper-parity + FFI-example matrix runs `--mm:refc` *and*
  `--mm:orc` on Windows. CI is green on Windows × Nim 2.2.4 + 2.2.10 across
  `nimble test`, `testApi`, `runTypeMapTestLib{Cpp,Py,Rust,Go}`, and
  `runFfiExample{Cpp,Py,Rust,Go}`. The raw `RegisterWaitForSingleObject`
  TLS-uninit hazard still exists at the OS level (probe reproduces it on
  refc), but broker code does not trip it — see `doc/LIMITATION.md` §2.2.
- Support matrix (`doc/LIMITATION.md` §1.2) is solid green across
  Linux + macOS (arm64/amd64) + Windows. Build floor is **Nim ≥ 2.2.0**
  (2.0.x refc deterministically SIGSEGVs on `seq[object]` FFI payloads, §2.1).

### Docs

- `doc/FFI_API.md` swept to the as-shipped CBOR-only runtime: corrected the
  request-path sequence diagram, cleaned the event-dispatch Mermaid diagram,
  dropped the native ABI box from the layered-architecture diagram, and
  replaced the native-shape "Type Mapping Reference" with a two-layer
  model + per-wrapper cheat-sheet pointing at `doc/TYPE_SURFACE.md` /
  `doc/TYPESUPPORT.md`. `-d:brokerDebug` now dumps generated AST to
  per-broker files under `build/broker_debug/` (README "## Debug").

## [2.1.0] — 2026-05-22

**FFI type-surface expansion — native `Option[T]`, primitive/void broker
types, tuples, and `seq[byte]` byte-string fidelity across all five
wrappers.**

- **Native `Option[T]` end-to-end** (phases e1–e3) for scalar, `string`,
  `seq[primitive]`, and registered-object inner types, across C / C++ /
  Python / Rust / Go in both native and CBOR modes. Uniform C-ABI layout:
  every `Option` field emits an explicit `<name>_has_value: bool` as the
  source of truth (not the `(nullptr, 0)` pattern), so a present-but-empty
  seq is distinguishable from an absent one. `Option[Object]` embeds the
  inner `<Inner>CItem` by value (no pointer indirection); readers must
  consult `has_value` first.
- **Primitive broker types** — `RequestBroker(API): type X = int32`,
  `EventBroker(API): type X = int64`. Codegen synthesises a single `value`
  field; the result/payload surfaces as a bare scalar. Across all broker
  variants (single-thread, MT, API) and all wrappers.
- **Void broker types** — `type X = void`. The parser lowers `void` to a
  unique empty object (unit type) so each broker keeps a distinct identity
  for `typedesc` dispatch; the new `ParsedBrokerType.isVoid` flag drops the
  value parameter. A void request carries only ok/err; a void event is a
  payload-less notification. Single-thread void events expose an argless
  listener/emit. CBOR C++ uses `jsoncons::json` for the empty envelope slot;
  CBOR Rust uses a `#[serde(skip)]` placeholder.
- **`seq[byte]` byte-string fidelity**: CBOR Python/Rust/Go inbound
  byte-string mapping; CBOR C++ now maps `seq[byte]` to
  `jsoncons::byte_string` (CBOR major type 2) in both directions — fixes
  jsoncons 1.7.0 encoding `std::vector<uint8_t>` as a CBOR array. Note:
  `byte_string` lacks `.empty()` (use `.size() == 0`).
- **Tuple-as-struct codegen + distinct-over-compound mapping** (CBOR), with
  per-tuple map writer/reader for wire alignment; `Option` fields partitioned
  into the `JSONCONS_N_MEMBER_TRAITS` tail.
- jsoncons 1.7.0 compatibility fix; distinct-over-seq registration.
- Fixed native C++ parity build: un-gated the eight `Option` tests from
  `#ifdef USE_CBOR`, and a missing comma in the void-event C++ trait
  signature. Native C++ parity 114/114, CBOR 119/119.
- New reference doc `doc/TYPE_SURFACE.md` — full Nim → C/C++/Rust/Go/Python
  API surface type mapping. Refreshed `BrokerDesignPrezi.html` MT + FFI
  sections; dropped the TownHall variant.

## [2.0.1] — 2026-05-13

**Hotfix: allow user overloads for MT broker payload field types.**

- `mtMarshalValue` / `mtUnmarshalValue` / `mtMarshalSeq` / `mtUnmarshalSeq`
  in `brokers/internal/mt_codec.nim` now declare `mixin mtMarshalValue` /
  `mixin mtUnmarshalValue`, so user-defined overloads for custom field /
  element types are picked up at instantiation site instead of being
  shadowed by the generic codec.

## [2.0.0] — 2026-05-13

**Multi-thread dispatch refactor — lock-free ring + pre-allocated slab + response-slot pool, replacing `Channel[T]`.**

- MT broker cross-thread dispatch was rebuilt off Nim stdlib `Channel[T]` onto
  a **Vyukov MPSC ring** carrying cell indices, a **pre-allocated payload
  slab** with refcounted cells, and (for `RequestBroker(mt)`) a
  **response-slot pool**. No per-emit / per-request shared-heap allocation;
  fan-out is a single slab encode + N ring enqueues with an atomic refcount.
- Up to **7.4× throughput** and **270× lower average latency** vs. the v1.x
  `Channel[T]` design on the cross-thread broadcast benchmark under refc.
  Full benchmark table in `doc/MT_BROKER_REFACTOR_RETROSPECTIVE.md`.
- Two production bugs closed (LIMITATION.md §2.2, §2.6 — both rooted in
  `Channel[T].storeAux` deep-copy interactions with the Nim allocator under
  refc/ORC).
- One shared `ThreadSignalPtr` per thread (shared across all `(mt)` broker
  types on the thread). fd count is **O(threads)**, not O(brokers × threads).
- New compile-time sizing knobs (`queueDepth`, `slabCapacity`,
  `maxPayloadBytes`, `responseSlots`, `maxResponseBytes`) with type-driven
  defaults and built-in presets (`fastBurst`, etc.). Every MT broker call
  site emits a compile-time `hint` line with the resolved values, their
  origin, and an idle-RAM estimate. See `doc/MT_BROKER_CONFIG.md`.
- New visible failure mode: bounded ring / pool can return `err(...)` /
  overflow on full — workloads that relied on `Channel[T]`'s unbounded
  buffering must size up or handle the error.
- New shared dispatcher hub `brokers/internal/mt_broker_common.nim`
  (`getOrInitBrokerSignal`, `registerBrokerPoller`, `brokerDispatchLoop`,
  `ensureBrokerDispatchStarted`, `fireBrokerSignal`,
  `drainPendingRingFrees`).
- Fixed a four-bug chain around FFI teardown:
  - Use `blockingRequest` (not `waitFor`) on the FFI caller's thread.
  - Synchronous deferred ring/slab/pool free on the provider thread.
  - Reordered delivery-thread teardown + added `drainPendingRingFrees`.
  - Tear down per-thread `brokerDispatchLoop` after FFI `waitFor`.
- New ASAN coverage for `test_multi_thread_broker_configs`.
- Resolved `EventBroker` / `RequestBroker` macro overload ambiguity on
  Nim 2.2.4.

**Breaking:**
- Internal MT broker layout changed; payloads no longer flow through
  `Channel[T]`. Anything that introspected the old layout must move to
  `mt_broker_common`.
- Bounded ring / pool means previously-unbounded workloads can now see
  enqueue overflow — review error handling on `emit` / `request`.

## [1.2.0] — 2026-05-11

**Go wrapper generation.**

- New `-d:BrokerFfiApiGenGo` flag emits a `<lib>_go/` module (cgo prelude +
  companion `.c` file for typed `//export` trampolines).
- Native and CBOR modes reach full parity with Rust on the typemappingtestlib
  matrix (41 native / 43 CBOR checks); idiomatic `(T, error)` returns,
  `Close()` + `runtime.SetFinalizer`, handler maps under `sync.Mutex`.
- Fixed per-event N×N fan-out and cross-context leakage in Rust + Go codegen.
- All FFI codegen backends (Py / Rust / Go) now emit both methods for
  dual-signature `RequestBroker(API)`.
- New `LIMITATION.md §2.1` Windows TLS-uninit probe; documented macOS + ORC
  `Channel[T]` UAF (§2.6).

## [1.1.0] — 2026-05-08

**Rust wrapper generation.**

- New `-d:BrokerFfiApiGenRust` flag emits a complete Cargo crate
  (`Cargo.toml` + `src/lib.rs`) next to the `.so`, with no bindgen/clang
  dependency — `extern "C"` blocks are hand-emitted.
- Native and CBOR modes reach full parity on the type matrix (primitives,
  enums, distinct/alias, `seq[T]`, `seq[string]`, `seq[Object]`,
  `array[N, primitive]`).
- CBOR-mode Rust uses a per-method `__Env<T>` envelope decoded directly via
  `ciborium` (no JSON intermediate — fixes `seq[byte]` round-trip).

## [1.0.0] — 2026-05-07

**CBOR FFI mode + first stable release.**

- New `-d:BrokerFfiApiCBOR` strategy: every library exposes a fixed 11-function
  ABI (`_initialize`, `_createContext`, `_shutdown`, `_allocBuffer`,
  `_freeBuffer`, `_call`, `_subscribe`, `_unsubscribe`, `_listApis`,
  `_getSchema`, `_version`). Wrappers carry the typed surface; wire format is
  CBOR.
- New `<lib>_version()` entry point on every FFI surface (C / C++ / Python /
  Rust / Go) returning the semver baked from `registerBrokerLibrary`.
- Per-library CMake package (`<lib>Config.cmake`) emitted alongside generated
  headers; new `testFfiApiCmake` task validates a downstream consumer.
- jsoncons vendored as a git submodule for CBOR-mode C++; new `fetchVendor`
  nimble task.
- Native ↔ CBOR Python and C++ wrapper parity: the **same** `cpp_example` and
  `python_example` sources compile and run against either build mode (toggled
  via `USE_CBOR=ON` in the CMake project / `MYLIB_BUILD_DIR` env var).
- Generated native C++ wrapper reshaped to mirror the CBOR `hpp` layout
  (typed `Lib` class, `Result<T>` API, `on/off` event API).
- CDDL schema emission for the CBOR FFI surface.

## [0.2.0] — 2026-05-05

**Type-support extension + Windows hardening.**

- Wider type matrix across the FFI surface (see `doc/TYPESUPPORT.md`):
  enums widened to `cint` to match the FFI ABI; richer object/seq/array
  coverage in typemappingtestlib.
- Multi-thread broker fixes: per-bucket channel + dispatch-signal leak plug,
  several broker FFI API teardown ordering fixes.
- Windows FFI builds standardized on `clang + lld + ninja + release UCRT`;
  emit a gnu-format `.lib` import library via `-Wl,--out-implib`; skip
  `--mm:refc` for MT and Broker FFI API tasks (chronos Win32
  `RegisterWaitForSingleObject` callback is unsafe under refc STW GC).
- CI: dropped Nim 2.0 from the matrix; split Nim `devel` into a non-blocking
  job; bumped memcheck options to Nim 2.2.10.
- Documented macOS + 2.2.4 + refc debug stdlib `Channel[T]` regression and
  skip the affected tests at compile time.

## [0.1.0] — 2026-04-01

**Initial standalone release.**

- Broker concept extracted from `logos-messaging` / `logos-delivery` into a
  standalone Nim library (`brokers` nimble package).
- Single-thread brokers: `EventBroker`, `RequestBroker` (async + sync modes),
  `MultiRequestBroker`.
- Multi-thread brokers: `EventBroker(mt)`, `RequestBroker(mt)` with
  `Lock`-protected shared bucket registry and per-bucket `ThreadSignalPtr`.
- `BrokerContext` scoping with thread-global binding and async scoped-swap
  templates.
- Broker FFI API generator (`registerBrokerLibrary`): C ABI entry points,
  generated C header, C++ wrapper, optional Python ctypes wrapper, two-thread
  runtime (delivery + processing).
- `typemappingtestlib` parity harness for C / C++ / Python.

[3.3.0]: https://github.com/NagyZoltanPeter/nim-brokers/releases/tag/v3.3.0
[3.2.0]: https://github.com/NagyZoltanPeter/nim-brokers/releases/tag/v3.2.0
[3.1.4]: https://github.com/NagyZoltanPeter/nim-brokers/releases/tag/v3.1.4
[3.1.3]: https://github.com/NagyZoltanPeter/nim-brokers/releases/tag/v3.1.3
[3.1.2]: https://github.com/NagyZoltanPeter/nim-brokers/releases/tag/v3.1.2
[3.1.1]: https://github.com/NagyZoltanPeter/nim-brokers/releases/tag/v3.1.1
[3.1.0]: https://github.com/NagyZoltanPeter/nim-brokers/releases/tag/v3.1.0
[3.0.0]: https://github.com/NagyZoltanPeter/nim-brokers/releases/tag/v3.0.0
[2.1.0]: https://github.com/NagyZoltanPeter/nim-brokers/releases/tag/v2.1.0
[2.0.1]: https://github.com/NagyZoltanPeter/nim-brokers/releases/tag/v2.0.1
[2.0.0]: https://github.com/NagyZoltanPeter/nim-brokers/releases/tag/v2.0.0
[1.2.0]: https://github.com/NagyZoltanPeter/nim-brokers/releases/tag/v1.2.0
[1.1.0]: https://github.com/NagyZoltanPeter/nim-brokers/releases/tag/v1.1.0
[1.0.0]: https://github.com/NagyZoltanPeter/nim-brokers/releases/tag/v1.0.0
[0.2.0]: https://github.com/NagyZoltanPeter/nim-brokers/releases/tag/v0.2.0
[0.1.0]: https://github.com/NagyZoltanPeter/nim-brokers/releases/tag/v0.1.0
