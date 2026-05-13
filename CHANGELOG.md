# Changelog

All notable changes to **nim-brokers** are documented here. The project follows
[Semantic Versioning](https://semver.org/). Dates are ISO-8601.

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

[2.0.0]: https://github.com/NagyZoltanPeter/nim-brokers/releases/tag/v2.0.0
[1.2.0]: https://github.com/NagyZoltanPeter/nim-brokers/releases/tag/v1.2.0
[1.1.0]: https://github.com/NagyZoltanPeter/nim-brokers/releases/tag/v1.1.0
[1.0.0]: https://github.com/NagyZoltanPeter/nim-brokers/releases/tag/v1.0.0
[0.2.0]: https://github.com/NagyZoltanPeter/nim-brokers/releases/tag/v0.2.0
[0.1.0]: https://github.com/NagyZoltanPeter/nim-brokers/releases/tag/v0.1.0
