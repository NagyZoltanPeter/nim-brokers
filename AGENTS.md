# AGENTS.md

This file provides guidance to when working with code in this repository.

## Project Overview

nim-brokers is a standalone Nim macro library (nimble package name: `brokers`) providing type-safe, decoupled messaging patterns built on top of **chronos** (async) and **results**. Originally extracted from the waku project. Modules are imported as `brokers/event_broker`, `brokers/request_broker`, `brokers/multi_request_broker`, and `brokers/broker_context`.

The repository also contains a **Broker FFI API** generator for exposing broker-based APIs as a shared library consumable from C, C++, and Python. The example library lives under `examples/ffiapi/nimlib/mylib.nim` and demonstrates generated lifecycle functions, request exports, event callback registration, a generated C++ wrapper, and an optional generated Python ctypes wrapper.

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
| Cross-thread dispatch | N/A | Via `AsyncChannel` per (context, thread) pair |
| Context binding | Per-thread bucket lookup | Per (brokerCtx, threadId, threadGen) triple |

Multi-thread brokers detect same-thread calls (direct dispatch) vs cross-thread calls (channel-based dispatch) automatically.

## Build & Test

The package is managed via `brokers.nimble`. Install dependencies and run all tests with:

```
nimble install -d
nimble test
nimble testApi
```

Current test task coverage:

- `nimble test` — core broker tests (single-thread + multi-thread variants across ORC/refc and debug/release settings as defined in `brokers.nimble`)
- `nimble testApi` — FFI API broker tests, including lifecycle/startup coverage for the generated shared-library runtime
- `nimble perftest` — performance and stress tests for the multi-thread brokers

To compile and run a single test file, always use `--outdir:build` to avoid polluting the git workspace with binaries:

```
nim c -r --outdir:build test/test_event_broker.nim
nim c -r --outdir:build test/test_request_broker.nim
nim c -r --outdir:build test/test_multi_request_broker.nim
nim c -r --outdir:build test/test_multi_thread_event_broker.nim
nim c -r --outdir:build test/test_multi_thread_request_broker.nim
nim c -r --outdir:build -d:BrokerFfiApi --threads:on --nimMainPrefix:apitestlib test/test_api_library_init.nim
```

The `build/` directory is in `.gitignore`. Never compile without `--outdir:build` as test binaries will otherwise land in `test/` and pollute git status.

Tests use `testutils/unittests` (not the stdlib `unittest`).

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
```

The C and C++ example binaries are built under `examples/ffiapi/cmake-build/`. The Python workflow generates `examples/ffiapi/nimlib/build/mylib.py` when compiled with `-d:BrokerFfiApiGenPy`.

### CI expectations

GitHub Actions CI currently runs:

- `nimble test`
- `nimble testApi`
- `nimble runFfiExampleC`
- `nimble runFfiExampleCpp`
- `nimble runFfiExamplePy`

Any change that affects broker runtime behavior, FFI generation, or example integration should preserve all of the above.

## Key Dependencies

- **chronos** — Async runtime (`Future`, `async`, `await`, `asyncSpawn`)
- **results** — `Result[T, E]` error handling (no exceptions in public APIs)
- **chronicles** — Structured logging (used in EventBroker for error reporting)
- **std/macros** — All three brokers are Nim macros that generate types and procs

## Architecture

### Code generation pattern

Each broker macro (`EventBroker`, `RequestBroker`, `MultiRequestBroker` and their `mt` variants) follows the same structure:

1. **Parse** the user-supplied type definition using shared helper `parseSingleTypeDef` in `src/helper/broker_utils.nim`.
2. **Generate** a type section (the value type, handler proc types, broker storage type) and all public API procs (`listen`/`emit`, `setProvider`/`request`/`clearProvider`, etc.).
3. Store state in a **thread-local global** (`{.threadvar.}`) for single-thread brokers, or **shared memory + threadvar** for multi-thread brokers.

### BrokerContext system (`src/broker_context.nim`)

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

### Multi-thread broker specifics (`src/mt_event_broker.nim`, `src/mt_request_broker.nim`)

- Global bucket registry: `Lock`-protected shared array of buckets, each identified by `(brokerCtx, threadId, threadGen)`.
- Thread identity: `addr mtThreadIdMarker` (threadvar address) + monotonic generation counter to disambiguate reused threadvar addresses across thread lifetimes.
- Same-thread dispatch: direct asyncSpawn (EventBroker) or direct provider call (RequestBroker).
- Cross-thread dispatch: `AsyncChannel` per bucket, with a `processLoop` on the listener/provider thread that reads from the channel.
- Initialization: atomic CAS-based one-time init per broker type.

### Broker FFI API specifics (`src/api_library.nim`, `src/api_common.nim`, `src/api_request_broker.nim`, `src/api_event_broker.nim`)

- `RequestBroker(API)` and `EventBroker(API)` generate C ABI entry points and wrapper metadata in addition to the normal broker interfaces.
- `registerBrokerLibrary` ties API request/event brokers into a complete shared-library surface.
- Generated lifecycle naming is intentionally split:
  - `<lib>_initialize()` — once-per-process Nim runtime initialization
  - `<lib>_create()` — per-context instance creation
  - `<lib>_shutdown(ctx)` — per-context shutdown
- `CreateRequest` is the post-create configuration broker; `DestroyRequest` is the orderly teardown broker.
- `mylib_create()` is readiness-synchronous: it returns only after the delivery thread installed event registration and the processing thread finished `setupProviders(ctx)`.
- The generated runtime uses two threads per created library context:
  - **delivery thread** — owns foreign event registration and executes foreign callbacks
  - **processing thread** — runs `setupProviders(ctx)` and executes request providers
- Generated Python wrapper support is optional and enabled with `-d:BrokerFfiApiGenPy`.

### Concurrency safety notes

All brokers are designed for chronos cooperative multitasking on a single thread per context. Key properties:

- **Snapshot-based dispatch (EventBroker):** `emit` copies the listener table into a local seq before spawning. This decouples dispatch from table mutation — `dropListener`/`dropAllListeners` during emit cannot corrupt iteration.
- **No implicit serialization (RequestBroker):** Multiple concurrent `request()` calls invoke the same provider concurrently. Providers that mutate shared state across `await` points are vulnerable to interleaved execution (provider reentrancy). This is inherent to async programming, not a broker bug. Use `AsyncLock` or stateless providers to protect against it.
- **Drop semantics:** `dropListener`/`dropAllListeners`/`clearProvider` take effect for future dispatches. Already-spawned in-flight work completes regardless. Callers shutting down resources must ensure in-flight work finishes before releasing resources.

## Source Files

```
src/
  api_common.nim            — Shared FFI code generation helpers for C/C++/Python surfaces
  api_event_broker.nim      — API-specific EventBroker generation helpers
  api_library.nim           — Shared-library lifecycle/runtime generator (`registerBrokerLibrary`)
  api_request_broker.nim    — API-specific RequestBroker generation helpers
  api_type.nim              — FFI-safe API type declarations (`ApiType`)
  broker_context.nim        — BrokerContext type, thread-global binding, async scoped templates
  event_broker.nim          — Single-thread EventBroker macro
  request_broker.nim        — Single-thread RequestBroker macro
  multi_request_broker.nim  — Single-thread MultiRequestBroker macro
  mt_event_broker.nim       — Multi-thread EventBroker(mt) macro
  mt_request_broker.nim     — Multi-thread RequestBroker(mt) macro
  mt_broker_common.nim      — Shared runtime helpers for MT brokers (thread ID, generation, blockingAwait)
  helper/
    broker_utils.nim        — Shared macro parsing utilities
examples/
  ffiapi/
    nimlib/mylib.nim        — Canonical Broker FFI API example library
    example/main.c          — Pure C consumer example
    cpp_example/main.cpp    — C++ wrapper consumer example
    python_example/main.py  — Python ctypes wrapper consumer example
test/
  test_event_broker.nim
  test_request_broker.nim
  test_multi_request_broker.nim
  test_multi_thread_event_broker.nim
  test_multi_thread_request_broker.nim
  test_api_request_broker.nim
  test_api_event_broker.nim
  test_api_library_init.nim
```

## Coding Conventions

- All source files use `{.push raises: [].}` or equivalent to enforce no-exception boundaries.
- Public async procs use `{.async: (raises: []).}` — errors are communicated through `Result`, not exceptions.
- Generated identifier names are sanitized via `sanitizeIdentName` to be safe Nim identifiers.
- Debug output of generated AST is available via `-d:brokerDebug` compile flags.
- Always compile with `--outdir:build` to keep binaries out of the source tree.
- For FFI API builds, keep the lifecycle naming distinction intact: `initialize` is process-wide, `create` is per-context.
- For FFI API builds, keep `--nimMainPrefix:<libname>` aligned with `name: "<libname>"` in `registerBrokerLibrary`.

## Formatting

- use `nimble nphall` command to format code properly always.
