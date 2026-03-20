# AGENTS.md

This file provides guidance to when working with code in this repository.

## Project Overview

nim-brokers is a standalone Nim macro library (nimble package name: `brokers`) providing type-safe, decoupled messaging patterns built on top of **chronos** (async) and **results**. Originally extracted from the waku project. Modules are imported as `brokers/event_broker`, `brokers/request_broker`, `brokers/multi_request_broker`, and `brokers/broker_context`.

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
```

To compile and run a single test file, always use `--outdir:build` to avoid polluting the git workspace with binaries:

```
nim c -r --outdir:build test/test_event_broker.nim
nim c -r --outdir:build test/test_request_broker.nim
nim c -r --outdir:build test/test_multi_request_broker.nim
nim c -r --outdir:build test/test_multi_thread_event_broker.nim
nim c -r --outdir:build test/test_multi_thread_request_broker.nim
```

The `build/` directory is in `.gitignore`. Never compile without `--outdir:build` as test binaries will otherwise land in `test/` and pollute git status.

Tests use `testutils/unittests` (not the stdlib `unittest`).

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

### Concurrency safety notes

All brokers are designed for chronos cooperative multitasking on a single thread per context. Key properties:

- **Snapshot-based dispatch (EventBroker):** `emit` copies the listener table into a local seq before spawning. This decouples dispatch from table mutation — `dropListener`/`dropAllListeners` during emit cannot corrupt iteration.
- **No implicit serialization (RequestBroker):** Multiple concurrent `request()` calls invoke the same provider concurrently. Providers that mutate shared state across `await` points are vulnerable to interleaved execution (provider reentrancy). This is inherent to async programming, not a broker bug. Use `AsyncLock` or stateless providers to protect against it.
- **Drop semantics:** `dropListener`/`dropAllListeners`/`clearProvider` take effect for future dispatches. Already-spawned in-flight work completes regardless. Callers shutting down resources must ensure in-flight work finishes before releasing resources.

## Source Files

```
src/
  broker_context.nim        — BrokerContext type, thread-global binding, async scoped templates
  event_broker.nim          — Single-thread EventBroker macro
  request_broker.nim        — Single-thread RequestBroker macro
  multi_request_broker.nim  — Single-thread MultiRequestBroker macro
  mt_event_broker.nim       — Multi-thread EventBroker(mt) macro
  mt_request_broker.nim     — Multi-thread RequestBroker(mt) macro
  mt_broker_common.nim      — Shared runtime helpers for MT brokers (thread ID, generation, blockingAwait)
  helper/
    broker_utils.nim        — Shared macro parsing utilities
test/
  test_event_broker.nim
  test_request_broker.nim
  test_multi_request_broker.nim
  test_multi_thread_event_broker.nim
  test_multi_thread_request_broker.nim
```

## Coding Conventions

- All source files use `{.push raises: [].}` or equivalent to enforce no-exception boundaries.
- Public async procs use `{.async: (raises: []).}` — errors are communicated through `Result`, not exceptions.
- Generated identifier names are sanitized via `sanitizeIdentName` to be safe Nim identifiers.
- Debug output of generated AST is available via `-d:brokerDebug` compile flags.
- Always compile with `--outdir:build` to keep binaries out of the source tree.

## Formatting

- use `nimble nphall` command to format code properly always.
