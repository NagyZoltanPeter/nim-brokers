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
nimble runTorpedoExamplePy # build and run the more complex torpedo example over Python bindings, implements game ui and orchestrator in Python
nimble runTorpedoExampleCpp # build and run the more complex torpedo example over C++ bindings, implements game ui and orchestrator in C++
```

The C and C++ example binaries are built under `examples/ffiapi/cmake-build/`. The Python workflow generates `examples/ffiapi/nimlib/build/mylib.py` when compiled with `-d:BrokerFfiApiGenPy`.

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
- `registerBrokerLibrary` ties API request/event brokers into a complete shared-library surface. It is a no-op when compiled without `-d:BrokerFfiApi`, so client code never needs a `when defined(BrokerFfiApi):` guard around it.
- `api_library` is always imported as part of the `brokers` package; no conditional import is needed in client code.
- External types used in broker signatures are auto-discovered and registered — plain Nim `object` types do not need any `ApiType` annotation. The deprecated `ApiType` macro still compiles with a warning.
- Generated lifecycle naming is intentionally split:
  - `<lib>_initialize()` — once-per-process Nim runtime initialization
  - `<lib>_createContext()` — per-context instance creation
  - `<lib>_shutdown(ctx)` — per-context shutdown
- `InitializeRequest` is the post-create configuration broker; `ShutdownRequest` is the orderly teardown broker.
- `<lib>_createContext()` is readiness-synchronous: it returns only after the delivery thread installed event registration and the processing thread finished `setupProviders(ctx)`.
- The generated runtime uses two threads per created library context:
  - **delivery thread** — owns foreign event registration and executes foreign callbacks
  - **processing thread** — runs `setupProviders(ctx)` and executes request providers
- Generated C header: `<libName>.h` (pure C), C++ wrapper: `<libName>.hpp` (includes the `.h`).
- Generated Python wrapper support is optional and enabled with `-d:BrokerFfiApiGenPy`.

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
    api_codegen_nim.nim     — Nim→C ABI type mapping (toCFieldType)
    api_event_broker.nim    — API-specific EventBroker generation helpers
    api_request_broker.nim  — API-specific RequestBroker generation helpers
    api_schema.nim          — Compile-time type registry (ApiTypeEntry, gApiTypeRegistry)
    api_type.nim            — Deprecated ApiType shim (use plain Nim types instead)
    api_type_resolver.nim   — Two-phase external type auto-resolution
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
  torpedo/                  - more complex demonstration of using API brokers, follows the same code and build structure as ffiapi example.
test/
  test_event_broker.nim
  test_request_broker.nim
  test_multi_request_broker.nim
  test_multi_thread_event_broker.nim
  test_multi_thread_request_broker.nim
  test_api_request_broker.nim
  test_api_event_broker.nim
  test_api_library_init.nim
  typemappingtestlib/       - exercises every Nim→C→C++/Python type mapping through FFI and generated bindings.
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

This project is indexed by GitNexus as **nim-brokers** (1046 symbols, 1709 relationships, 10 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

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
