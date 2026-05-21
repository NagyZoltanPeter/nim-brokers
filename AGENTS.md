# AGENTS.md

This file provides guidance to when working with code in this repository.

## Project Overview

nim-brokers is a standalone Nim macro library (nimble package name: `brokers`) providing type-safe, decoupled messaging patterns built on top of **chronos** (async) and **results**. Originally extracted from the waku project. Modules are imported as `brokers/event_broker`, `brokers/request_broker`, `brokers/multi_request_broker`, and `brokers/broker_context`.

The repository also contains a **Broker FFI API** generator for exposing broker-based APIs as a shared library consumable from C, C++, Python, Rust, and Go. The example library lives under `examples/ffiapi/nimlib/mylib.nim` and demonstrates generated lifecycle functions, request exports, event callback registration, a generated C++ wrapper, an optional generated Python ctypes wrapper, an optional generated Rust crate, and an optional generated Go cgo module.

There are three broker macros, each with a single-thread and multi-thread variant:

- **EventBroker** / **EventBroker(mt)** — Reactive pub/sub: many emitters to many listeners. Listeners are async procs registered via `TypeName.listen(...)`, events fired with `TypeName.emit(...)`.
- **RequestBroker** / **RequestBroker(mt)** — Single-provider request/response. Supports both `async` (default) and `sync` modes via `RequestBroker(sync):`. A provider is registered with `TypeName.setProvider(...)`, requests made with `TypeName.request(...)`.
- **MultiRequestBroker** — Multi-provider fan-out request/response (async only). Multiple providers register; `request()` calls all of them and aggregates results.

All brokers support **BrokerContext** for scoping — allowing multiple independent broker instances (e.g. one per component or per thread). The default context (`DefaultBrokerContext`) is used when no context argument is supplied.

### Single-thread vs Multi-thread brokers

| Aspect | Single-thread (`EventBroker`, `RequestBroker`) | Multi-thread (`EventBroker(mt)`, `RequestBroker(mt)`) |
|--------|-----------------------------------------------|------------------------------------------------------|
| State storage | Thread-local global (`{.threadvar.}`) | Shared memory (`createShared`) + per-thread threadvar |
| Thread safety | None needed (single event loop) | `Lock`-protected global bucket registry |
| Cross-thread dispatch | N/A | Via `Channel[T]` (0 fds) per (context, thread) + one shared `ThreadSignalPtr` per thread |
| Context binding | Per-thread bucket lookup | Per (brokerCtx, threadId, threadGen) triple |

Multi-thread brokers detect same-thread calls (direct dispatch) vs cross-thread calls (channel-based dispatch) automatically.

## Build & Test

The package is managed via `brokers.nimble`. Install dependencies and run all tests with:

```
nimble install -d
nimble test
nimble testApi
nimble testFfiApi
nimble testFfiApiCpp
```

Current test task coverage:

- `nimble test` — core broker tests (single-thread + multi-thread variants across ORC/refc and debug/release settings as defined in `brokers.nimble`)
- `nimble testApi` — FFI API broker tests, including lifecycle/startup coverage for the generated shared-library runtime
- `nimble testFfiApi` — tests for the FFI API generation components (type resolver, codegen modules, schema registry)
- `nimble testFfiApiCpp` — C++ wrapper tests for the FFI API (builds and runs the C++ example consumer)
- `nimble testFfiApiCmake` — Validates the generated `<lib>Config.cmake` package by configuring and building a downstream consumer in `test/cmake_consumer/` via `find_package(mylib CONFIG REQUIRED)` and linking smoke binaries against the IMPORTED targets `mylib::mylib` (C) and `mylib::mylib_cpp` (C++)
- `nimble testApiCbor` — CBOR-mode FFI tests: codec round-trips, library lifecycle, event subscribe, discovery API, and the typemappingtestlib CBOR parity matrix (Nim side) across ORC/refc × debug/release
- `nimble runTypeMapTestLibRust` / `runTypeMapTestLibCborRust` — Rust parity matrix for the typemappingtestlib (native and CBOR builds; requires stable Rust 1.75+ via rustup)
- `nimble runTypeMapTestLibGo` / `runTypeMapTestLibCborGo` — Go parity matrix for the typemappingtestlib (native and CBOR builds; requires Go 1.21+ on PATH)
- `nimble perftest` — performance and stress tests for the multi-thread brokers

To compile and run a single test file, always use `--outdir:build` to avoid polluting the git workspace with binaries:

```
nim c -r --path:. --outdir:build test/test_event_broker.nim
nim c -r --path:. --outdir:build test/test_request_broker.nim
nim c -r --path:. --outdir:build test/test_multi_request_broker.nim
nim c -r --path:. --outdir:build --threads:on test/test_multi_thread_event_broker.nim
nim c -r --path:. --outdir:build --threads:on test/test_multi_thread_request_broker.nim
nim c -r --path:. --outdir:build -d:BrokerFfiApi --threads:on --nimMainPrefix:apitestlib test/test_api_library_init.nim
```

The `build/` directory is in `.gitignore`. Never compile without `--outdir:build` as test binaries will otherwise land in `test/` and pollute git status.

Tests use `testutils/unittests` (not the stdlib `unittest`).

### Formatting

- use `nimble nphall` command to format code properly always.

### FFI API example build and run tasks

The FFI example library and runnable consumers are driven from Nimble tasks:

```
nimble buildFfiExample      # build examples/ffiapi/nimlib/mylib.nim as shared library
nimble buildFfiExamplePy    # same, plus generated Python wrapper
nimble buildFfiExampleC     # build the pure C example via CMake
nimble buildFfiExampleCpp   # build the C++ example via CMake
nimble buildFfiExamples     # build both C and C++ examples via CMake
nimble runFfiExampleC       # rebuild library + run C example
nimble runFfiExampleCpp     # rebuild library + run C++ example
nimble runFfiExamplePy      # rebuild library + generated wrapper + run Python example
nimble runFfiExampleRust    # rebuild library + generated Rust crate + run native Rust example
nimble runFfiExampleCborRust # CBOR-mode counterpart of runFfiExampleRust
nimble runFfiExampleGo       # rebuild library + generated Go module + run native Go example
nimble runFfiExampleCborGo   # CBOR-mode counterpart of runFfiExampleGo
nimble runTorpedoExamplePy # build and run the more complex torpedo example over Python bindings, implements game ui and orchestrator in Python
nimble runTorpedoExampleCpp # build and run the more complex torpedo example over C++ bindings, implements game ui and orchestrator in C++
nimble runTorpedoExampleRust    # native Rust torpedo example
nimble runTorpedoExampleCborRust # CBOR-mode Rust torpedo example
nimble runTorpedoExampleGo       # native Go torpedo example
nimble runTorpedoExampleCborGo   # CBOR-mode Go torpedo example
```

The C and C++ example binaries are built under `examples/ffiapi/cmake-build/`. The Python workflow generates `examples/ffiapi/nimlib/build/mylib.py` when compiled with `-d:BrokerFfiApiGenPy`. The Rust workflow generates a complete Cargo crate at `examples/ffiapi/nimlib/build/mylib_rs/` (or `build_cbor/mylib_rs/` for CBOR mode) when compiled with `-d:BrokerFfiApiGenRust`. Consumers include it via a `#[path]` module declaration so a single example crate can switch between modes via Cargo features.

#### CBOR-mode FFI tasks

`-d:BrokerFfiApi` selects the CBOR strategy: every library exposes a fixed 11-function ABI (`<lib>_version`, `_initialize`, `_createContext`, `_shutdown`, `_allocBuffer`, `_freeBuffer`, `_call`, `_subscribe`, `_unsubscribe`, `_listApis`, `_getSchema`) plus a typedef for the event callback. Wrappers carry the typed surface; wire format is CBOR.

Both ABI modes (native and CBOR) additionally expose `<lib>_version() -> const char*` returning the static semver string baked from the `version:` field of `registerBrokerLibrary` (default `0.1.0`). The pointer references library-owned static storage and must NOT be freed by the caller. Wrappers re-export it as a class member: `<Lib>::version() -> std::string_view` (C++ static method) and `<Lib>.version() -> str` (Python `@staticmethod`). Both can be called without an instance — no context, no library lifecycle required.

The CBOR-mode example builds reuse the SAME `examples/ffiapi/` and `examples/torpedo/` sources as the native builds — `mylib.nim` / `torpedolib.nim` are compiled with `-d:BrokerFfiApi` into `nimlib/build_cbor/`, and the existing `cpp_example/main.cpp` is linked against the CBOR-generated header (via `-DUSE_CBOR=ON` in the CMake project). This is the parity-validation harness: the same C++ client compiles cleanly against either build mode.

```
nimble buildFfiExampleCbor          # mylib.nim with -d:BrokerFfiApi -> examples/ffiapi/nimlib/build_cbor/
nimble buildFfiExampleCborCpp       # above + cmake (USE_CBOR=ON) build of cpp_example
nimble runFfiExampleCborCpp         # above + run the CBOR-built C++ example
nimble buildTorpedoExampleCbor      # same for torpedo
nimble buildTorpedoExampleCborCpp
nimble runTorpedoExampleCborCpp
nimble buildTypeMapTestLibCbor      # build the parity test library
nimble runTypeMapTestLibCborPy      # run the Python parity matrix
nimble runTypeMapTestLibCborCpp     # run the C++ parity matrix
```

External dependencies for CBOR-mode wrappers:
- C++: jsoncons (header-only) under `vendor/jsoncons/include`. Vendored as a
  git submodule pinned to a tagged release. After cloning the repo, run
  `nimble fetchVendor` (or `git submodule update --init --recursive`) to
  populate it before building any CBOR C++ target.
- Python: the `cbor2` package on the active interpreter (`pip install --user cbor2`).
- Rust: stable toolchain (MSRV 1.75+) via rustup. Cargo fetches `ciborium`,
  `serde`, `serde_json`, `serde_bytes` automatically when building with
  `--features cbor`. Native-mode Rust builds need only the toolchain — no
  external crates.
- Go: 1.21+ toolchain on PATH. CBOR-mode builds fetch
  `github.com/fxamacker/cbor/v2` automatically via `go mod tidy`. Native
  builds need only the toolchain — no external modules.

#### Foreign-language wrapper generation flags

| Flag | Generates | Output location |
|------|-----------|-----------------|
| `-d:BrokerFfiApiGenPy` | `<lib>.py` ctypes wrapper | next to the `.so` |
| `-d:BrokerFfiApiGenRust` | `<lib>_rs/` Cargo crate (Cargo.toml + src/lib.rs) | next to the `.so` |
| `-d:BrokerFfiApiGenGo` | `<lib>_go/` Go module (go.mod + `<lib>.go` (native, build-tag `!cbor`) + `<lib>_cbor.go` (cbor) + companion `.c` files for cgo callbacks) | next to the `.so` |

C and C++ headers are always emitted; Python, Rust, and Go are opt-in.

##### Rust codegen scope

Native- and CBOR-mode Rust have **full parity** for both requests and events across the type matrix the typemappingtestlib parity test exercises: primitive scalars (bool / intN / uintN / byte / floatN / string), enums (`#[repr(i32)]` Rust enums with `From<i32>`), distinct/alias (`pub type X = Y`), `seq[primitive]` (`Vec<T>`), `seq[string]` (`Vec<String>`), `seq[Object]` (`Vec<T>` with all-primitive/string fields), and `array[N, primitive]` (`Vec<T>`). The same client code drives either build mode unchanged.

Per-mode shape:

- **Native**: `extern "C"` blocks declare typed pointers (`*const T` for `seq[primitive]`, `*const *const c_char` for `seq[string]`, `*const TCItem` for `seq[Object]`). Request methods marshal Rust `Vec<T>` to/from C-side `(ptr, count)` pairs. Each event has a per-event extern `fn` typedef, a per-event dispatcher `static`, and a generated trampoline that converts FFI args to safe Rust values (Vec/String/enum/distinct) before fanning out to subscribed closures via `Arc<dyn Fn(...) + Send + Sync>` snapshot-and-clone.
- **CBOR**: per-method response decode goes directly from CBOR bytes into the typed `#[derive(Deserialize)]` struct via a per-method `__Env<T>` envelope (no JSON intermediate, so `seq[byte]` and other byte-string fields preserve type fidelity). Events share one trampoline that demuxes by `(ctx, event_name)` and decodes the payload via `ciborium` into the typed event struct, then unpacks fields and fans out to the user closure with the **same** `Fn(field1, field2, ...)` signature the native build uses.

Edge cases still left as `// TODO(rust-codegen)` stubs in native mode (CBOR handles them): `seq[Object]` where the object contains nested objects or composite fields (the codegen restricts `seq[T]` element objects to those with primitive/string fields only); `array[N, Object]`; `array[N, string]`. None of the example libraries hit these cases.

##### Go codegen scope

Native- and CBOR-mode Go have **full parity** with Rust on the type matrix the typemappingtestlib parity test exercises (41 native checks, 43 CBOR including `ObjParamRequest`). The public surface is idiomatic Go: `(T, error)` returns instead of `Result<T>`, `Close()` + `runtime.SetFinalizer` instead of `Drop`, and event handlers as plain Go func values stored in a `map[uint64]Handler` keyed by the registration handle.

Per-mode shape:

- **Native**: cgo `extern "C"` declarations cast through the typed `<EventName>CCallback` function-pointer typedef. The `<lib>.go` cgo prelude declares register-helpers (`go_register_<Event>(ctx)`); their bodies live in a companion `<lib>_callbacks.c` that `#include`s `_cgo_export.h` so cgo's typed `GoUint32`/`GoInt64` extern declarations of the `//export`'d Go trampolines are visible to the cast (avoids the "conflicting types" error you hit declaring the trampoline yourself in the prelude). Each event has its own dispatcher map + trampoline; on call, the trampoline converts cgo C args to safe Go values, snapshots the map under `sync.Mutex`, then fans out.
- **CBOR**: a single `//export goCborEventTrampoline` demuxes by `(ctx, eventName)` via a per-context handler registry and decodes the payload into the typed event struct via `github.com/fxamacker/cbor/v2`. Per-method `__Env`-style envelope (`struct{ Ok *T; Err *string }`) decodes the CBOR response directly into the typed struct — same fix the Rust CBOR codegen needed to make `seq[byte]` round-trip.

Two intentional ergonomic divergences from the C++/Rust surface (forced by Go semantics):
1. Event closures take unpacked fields (`func(p Priority, j int32, ts int64)`) but cannot capture `&self` because Go closures stored in a map need `Send + Sync + 'static`-equivalent shape; users that want lib state inside the handler close over it themselves.
2. `Off<Event>(handle uint64)` requires an explicit handle (no default-zero "remove all") to keep the Go signature simple.

Edge cases left as `// TODO(go-codegen)` stubs match the Rust set: `array[N, Object]`, `array[N, string]`, `seq[Object<seq>]` in native mode (CBOR handles them); object-as-request-param native (broker gated to `-d:BrokerFfiApi`).

#### Examine generated nim code

Sometimes it is useful to examine the Nim code generated by the macros. This can be done by compiling with the `-d:brokerDebug` flag, which will print the generated AST to the console. For example:

```
nim c -d:BrokerFfiApi --threads:on --app:lib --path:. --outdir:examples/ffiapi/nimlib/build -d:brokerDebug  --nimMainPrefix:mylib examples/ffiapi/nimlib/mylib.nim
```
or with such command template:
```
nim c -d:BrokerFfiApi --threads:on --app:lib --path:. --outdir:build -d:brokerDebug --nimMainPrefix:<prefix> <file-to-compile>
```

### CI expectations

GitHub Actions CI currently runs:

- `nimble test`
- `nimble testApi`
- `nimble testFfiApi`
- `nimble testFfiApiCpp`
- `nimble testApiCbor`
- `nimble runFfiExampleC`
- `nimble runFfiExampleCpp`
- `nimble runFfiExamplePy`
- `nimble runFfiExampleCborCpp`
- `nimble runTypeMapTestLibCborPy`
- `nimble runTypeMapTestLibCborCpp`
- `nimble runFfiExampleRust`
- `nimble runFfiExampleCborRust`
- `nimble runTypeMapTestLibRust`
- `nimble runTypeMapTestLibCborRust`
- `nimble runFfiExampleGo`
- `nimble runFfiExampleCborGo`
- `nimble runTypeMapTestLibGo`
- `nimble runTypeMapTestLibCborGo`

Any change that affects broker runtime behavior, FFI generation, or example integration should preserve all of the above.

## Key Dependencies

- **chronos** — Async runtime (`Future`, `async`, `await`, `asyncSpawn`)
- **results** — `Result[T, E]` error handling (no exceptions in public APIs)
- **chronicles** — Structured logging (used in EventBroker for error reporting)
- **std/macros** — All three brokers are Nim macros that generate types and procs

## Architecture

### Code generation pattern

Each broker macro (`EventBroker`, `RequestBroker`, `MultiRequestBroker` and their `mt` variants) follows the same structure:

1. **Parse** the user-supplied type definition using shared helper `parseSingleTypeDef` in `brokers/internal/helper/broker_utils.nim`.
2. **Generate** a type section (the value type, handler proc types, broker storage type) and all public API procs (`listen`/`emit`, `setProvider`/`request`/`clearProvider`, etc.).
3. Store state in a **thread-local global** (`{.threadvar.}`) for single-thread brokers, or **shared memory + threadvar** for multi-thread brokers.

### BrokerContext system (`brokers/broker_context.nim`)

`BrokerContext` is a `distinct uint32` used to multiplex independent broker instances. `NewBrokerContext()` generates globally unique IDs via an atomic counter (`fetchAdd`, thread-safe).

#### Thread-global context binding

Each thread has a thread-global BrokerContext (defaults to `DefaultBrokerContext`). Two sync procs are available for thread init (usable before the event loop starts):

- `setThreadBrokerContext(ctx)` — Adopts an externally-created context as this thread's global. Primary use case: main thread creates context, passes to processing thread, processing thread adopts it.
- `initThreadBrokerContext(): BrokerContext` — Creates a new context and sets it as thread-global in one call. Returns the context for propagation.
- `threadGlobalBrokerContext(): BrokerContext` — Reads the thread's current context (lock-free threadvar read). `globalBrokerContext()` is a backward-compatible alias.

For async scoped context swapping, `lockGlobalBrokerContext` and `lockNewGlobalBrokerContext` templates are available (require chronos event loop).

### Type handling for non-object types

When a broker type is declared as a native type, alias, or externally-defined type (not an inline `object`/`ref object`), the macros automatically wrap it in `distinct` to prevent overload ambiguity. If the user already wrote `distinct`, it is preserved as-is.

### EventBroker specifics

- Listeners stored in a `Table[uint64, HandlerProc]` per context bucket.
- `emit` snapshots the listener list then calls `asyncSpawn` per listener (fire-and-forget).
- Inline object types get extra `emit` overloads that accept fields directly (e.g. `TypeName.emit(field1 = val1, field2 = val2)`).
- `dropListener` removes a listener from the table. Already-spawned in-flight futures for the current emit cycle will still complete (snapshot was taken before drop).
- `dropAllListeners` clears all listeners for a context. Same in-flight behavior as `dropListener`.

### RequestBroker specifics

- Supports two independent signature slots: zero-argument and argument-based.
- `RequestBroker(sync):` generates synchronous procs (`{.gcsafe, raises: [].}`) instead of async ones.
- Provider exceptions are caught and returned as `err(...)`.
- `clearProvider` removes the provider. In-flight requests that already hold a reference to the provider closure will complete naturally; the caller gets the result or error.

### MultiRequestBroker specifics

- Async only (no sync mode).
- Multiple providers per signature; `request()` fans out to all via `allFinished`.
- Fails the entire request if any provider fails.
- Deduplicates identical handler references on registration.

### Multi-thread broker specifics (`brokers/internal/mt_event_broker.nim`, `brokers/internal/mt_request_broker.nim`)

- Global bucket registry: `Lock`-protected shared array of buckets, each identified by `(brokerCtx, threadId, threadGen)`.
- Thread identity: `addr mtThreadIdMarker` (threadvar address) + monotonic generation counter to disambiguate reused threadvar addresses across thread lifetimes.
- Same-thread dispatch: direct asyncSpawn (EventBroker) or direct provider call (RequestBroker).
- Cross-thread dispatch: `Channel[T]` (0 OS fds) per bucket. A single shared `ThreadSignalPtr` per thread wakes one `brokerDispatchLoop` coroutine that drains all registered `ThreadDispatchPollFn` closures via non-blocking `tryRecv`. fd count: **O(threads)** regardless of broker type count.
- Shared dispatcher infrastructure lives in `brokers/internal/mt_broker_common.nim`: `getOrInitBrokerSignal`, `registerBrokerPoller`, `brokerDispatchLoop`, `ensureBrokerDispatchStarted`, `fireBrokerSignal`.
- Initialization: atomic CAS-based one-time init per broker type.

### Broker FFI API specifics (`brokers/api_library.nim`, `brokers/internal/api_common.nim`, `brokers/internal/api_request_broker.nim`, `brokers/internal/api_event_broker.nim`)

- `RequestBroker(API)` and `EventBroker(API)` generate C ABI entry points and wrapper metadata in addition to the normal broker interfaces.
- `RequestBroker(API, ...)` / `EventBroker(API, ...)` accept the **same capacity / preset kwargs as their `(mt, ...)` counterparts** — the API broker rides the multi-thread lane internally, so `queueDepth`, `slabCapacity`, `maxPayloadBytes`, `responseSlots`, `maxResponseBytes`, `freeListShards`, and `preset = <name>` are all valid. Omitting kwargs yields `defaultMtEvtCfg()` / `defaultMtReqCfg()`.
- `registerBrokerLibrary` ties API request/event brokers into a complete shared-library surface. It is a no-op when compiled without `-d:BrokerFfiApi`, so client code never needs a `when defined(BrokerFfiApi):` guard around it.
- `api_library` is always imported as part of the `brokers` package; no conditional import is needed in client code.
- External types used in broker signatures are auto-discovered and registered — plain Nim `object` types do not need any `ApiType` annotation. The deprecated `ApiType` macro still compiles with a warning.
- Generated lifecycle naming is intentionally split:
  - `<lib>_initialize()` — once-per-process Nim runtime initialization
  - `<lib>_createContext()` — per-context instance creation
  - `<lib>_shutdown(ctx)` — per-context shutdown
- `InitializeRequest` is the post-create configuration broker; `ShutdownRequest` is the orderly teardown broker.
- `<lib>_createContext()` is readiness-synchronous: it returns only after the delivery thread has installed its event-courier poller and the processing thread has finished `setupProviders(ctx)` plus per-event listener installation.
- The generated runtime uses two threads per created library context:
  - **delivery thread** — consumes the per-context event courier ring and invokes foreign callbacks. Spawned first so its broker dispatch signal is published before any emit can fire.
  - **processing thread** — runs `setupProviders(ctx)`, installs per-event listeners (same-thread fast path for the FFI lane), executes request providers, and produces event-courier messages on emit.
- FFI subscribe / unsubscribe (`<lib>_subscribe` / `<lib>_unsubscribe`) write the shared `SubsRegistry` directly from the foreign caller's thread and bump a per-event `Atomic[int]` counter; the emit-side reads the counter lock-free to short-circuit the courier path when no foreign subscriber is registered. See `doc/CBOR_Round2_PartD_EventCourier.md` for the three-lane dispatch design and `doc/bench_baseline.md` § "Event dispatch — Part D-6" for per-emit costs.
- Generated C header: `<libName>.h` (pure C), C++ wrapper: `<libName>.hpp` (includes the `.h`).
- Generated Python wrapper support is optional and enabled with `-d:BrokerFfiApiGenPy`.
- Generated Rust wrapper support is optional and enabled with `-d:BrokerFfiApiGenRust`. It emits a complete Cargo crate `<libName>_rs/` (Cargo.toml + src/lib.rs) next to the `.so`. The crate declares the C ABI via hand-written `extern "C"` blocks (no bindgen / no clang dep) and exposes the same `Lib::new() / create_context() / <request>(args) -> Result<T, String> / on_<event> / off_<event> / shutdown / Drop` surface the C++ wrapper provides.

### Concurrency safety notes

All brokers are designed for chronos cooperative multitasking on a single thread per context. Key properties:

- **Snapshot-based dispatch (EventBroker):** `emit` copies the listener table into a local seq before spawning. This decouples dispatch from table mutation — `dropListener`/`dropAllListeners` during emit cannot corrupt iteration.
- **No implicit serialization (RequestBroker):** Multiple concurrent `request()` calls invoke the same provider concurrently. Providers that mutate shared state across `await` points are vulnerable to interleaved execution (provider reentrancy). This is inherent to async programming, not a broker bug. Use `AsyncLock` or stateless providers to protect against it.
- **Drop semantics:** `dropListener`/`dropAllListeners`/`clearProvider` take effect for future dispatches. Already-spawned in-flight work completes regardless. Callers shutting down resources must ensure in-flight work finishes before releasing resources.

## Source Files

```
brokers/
  broker_context.nim        — BrokerContext type, thread-global binding, async scoped templates
  event_broker.nim          — Single-thread EventBroker macro (re-exports internal/mt_event_broker when --threads:on)
  request_broker.nim        — Single-thread RequestBroker macro (re-exports internal/mt_request_broker when --threads:on)
  multi_request_broker.nim  — Single-thread MultiRequestBroker macro
  api_library.nim           — Shared-library lifecycle/runtime generator (`registerBrokerLibrary`)
  internal/
    api_common.nim          — Re-export hub for all codegen modules + legacy bridge + runtime memory helpers
    api_codegen_c.nim       — C type mapping, accumulators, header generation (.h)
    api_codegen_cpp.nim     — C++ type mapping, accumulators, wrapper generation (.hpp)
    api_codegen_python.nim  — Python type mapping, accumulators, wrapper generation (.py)
    api_codegen_rust.nim    — Native-mode Rust type mapping, accumulators, Cargo crate generation (Cargo.toml + src/lib.rs)
    api_codegen_go.nim      — Native-mode Go type mapping, accumulators, cgo Go module generation (go.mod + <lib>.go + <lib>_callbacks.c)
    api_codegen_nim.nim     — Nim→C ABI type mapping (toCFieldType)
    api_event_broker.nim    — API-specific EventBroker generation helpers
    api_request_broker.nim  — API-specific RequestBroker generation helpers
    api_schema.nim          — Compile-time type registry (ApiTypeEntry, gApiTypeRegistry)
    api_type.nim            — Deprecated ApiType shim (use plain Nim types instead)
    api_type_resolver.nim   — Two-phase external type auto-resolution
    api_ffi_mode.nim        — BrokerFfiMode enum + brokerFfiMode flag-driven const
    api_cbor_codec.nim      — BrokerCbor flavor, encode/decode helpers, distinct/enum bindings
    api_cbor_descriptor.nim — Stable runtime descriptor types for the discovery API
    api_request_broker_cbor.nim — CBOR-mode RequestBroker(API) codegen + per-request adapter
    api_event_broker_cbor.nim   — CBOR-mode EventBroker(API) codegen + per-event entry registration
    api_codegen_cbor_h.nim   — Fixed-shape C header for CBOR-mode libraries
    api_codegen_cbor_hpp.nim — jsoncons-backed C++ wrapper (typed Lib class, traits)
    api_codegen_cbor_py.nim  — cbor2-backed Python wrapper (dataclasses, typed methods)
    api_codegen_cbor_rust.nim — ciborium+serde-backed Rust crate (typed Lib struct, per-method __Env<T> envelope)
    api_codegen_cbor_go.nim  — fxamacker/cbor-backed Go module (typed Lib struct, per-method `__Env`-style envelope, `//go:build cbor`)
    api_codegen_cbor_cddl.nim — CDDL schema emission for the CBOR FFI surface
    mt_event_broker.nim     — Multi-thread EventBroker(mt) macro
    mt_request_broker.nim   — Multi-thread RequestBroker(mt) macro
    mt_broker_common.nim    — Shared runtime helpers for MT brokers (thread ID, generation, blockingAwait)
    helper/
      broker_utils.nim      — Shared macro parsing utilities
examples/
  ffiapi/
    nimlib/mylib.nim        — Canonical Broker FFI API example library
    example/main.c          — Pure C consumer example
    cpp_example/main.cpp    — C++ wrapper consumer example
    python_example/main.py  — Python ctypes wrapper consumer example
    rust_example/           — Rust crate consumer example (Cargo.toml + build.rs + src/main.rs); switches build modes via the `cbor` Cargo feature
    go_example/             — Go module consumer example (go.mod + main.go + main_native.go + main_cbor.go); switches build modes via Go build tags
  torpedo/                  - more complex demonstration of using API brokers, follows the same code and build structure as ffiapi example (now includes a `rust_example/` and `go_example/` alongside the C++/Python ones).
test/
  test_event_broker.nim
  test_request_broker.nim
  test_multi_request_broker.nim
  test_multi_thread_event_broker.nim
  test_multi_thread_request_broker.nim
  test_api_request_broker.nim
  test_api_event_broker.nim
  test_api_library_init.nim
  typemappingtestlib/       - exercises every Nim→C→C++/Python/Rust/Go type mapping through FFI and generated bindings. Includes a `rust_test/` Cargo crate and a `go_test/` Go module that run the same parity matrix as `test_typemappingtestlib.{cpp,py}`.
```

## Coding Conventions

- All source files use `{.push raises: [].}` or equivalent to enforce no-exception boundaries.
- Public async procs use `{.async: (raises: []).}` — errors are communicated through `Result`, not exceptions.
- Generated identifier names are sanitized via `sanitizeIdentName` to be safe Nim identifiers.
- Debug output of generated AST is available via `-d:brokerDebug` compile flags.
- Always compile with `--outdir:build` to keep binaries out of the source tree.
- Allways import with `broker/...`
- For FFI API builds, keep the lifecycle naming distinction intact: `createContext`/`shutdown(ctx)`.
- For FFI API builds, keep `--nimMainPrefix:<libname>` aligned with `name: "<libname>"` in `registerBrokerLibrary`.

### C/C++

- We use cmake projects to build C/C++ examples, test codes if any.
- We enforce C++20 standard for C++ code, and C11 for C code.

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **nim-brokers** (5295 symbols, 9362 relationships, 244 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> If any GitNexus tool warns the index is stale, run `npx gitnexus analyze` in terminal first.

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `gitnexus_impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `gitnexus_detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `gitnexus_query({query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `gitnexus_context({name: "symbolName"})`.

## Never Do

- NEVER edit a function, class, or method without first running `gitnexus_impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `gitnexus_rename` which understands the call graph.
- NEVER commit changes without running `gitnexus_detect_changes()` to check affected scope.

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/nim-brokers/context` | Codebase overview, check index freshness |
| `gitnexus://repo/nim-brokers/clusters` | All functional areas |
| `gitnexus://repo/nim-brokers/processes` | All execution flows |
| `gitnexus://repo/nim-brokers/process/{name}` | Step-by-step execution trace |

## CLI

| Task | Read this skill file |
|------|---------------------|
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus/gitnexus-cli/SKILL.md` |

<!-- gitnexus:end -->
