# AGENTS.md

This file provides guidance to when working with code in this repository.

## Project Overview

nim-brokers is a standalone Nim macro library (nimble package name: `brokers`) providing type-safe, thread-local, decoupled messaging patterns built on top of **chronos** (async) and **results**. Originally extracted from the waku project. Modules are imported as `brokers/event_broker`, `brokers/request_broker`, `brokers/multi_request_broker`, and `brokers/broker_context`.

There are three broker macros, each generating all boilerplate at compile time:

- **EventBroker** — Reactive pub/sub: many emitters → many listeners. Listeners are async procs registered via `TypeName.listen(...)`, events fired with `TypeName.emit(...)`.
- **RequestBroker** — Single-provider request/response. Supports both `async` (default) and `sync` modes via `RequestBroker(sync):`. A provider is registered with `TypeName.setProvider(...)`, requests made with `TypeName.request(...)`.
- **MultiRequestBroker** — Multi-provider fan-out request/response (async only). Multiple providers register; `request()` calls all of them and aggregates results.

All three support **BrokerContext** for scoping — allowing multiple independent broker instances per thread (e.g. one per component). The default context (`DefaultBrokerContext`) is used when no context argument is supplied.

## Build & Test

The package is managed via `brokers.nimble`. Install dependencies and run all tests with:

```
nimble install -d
nimble test
```

To compile and run a single test file:

```
nim c -r test/test_event_broker.nim
nim c -r test/test_request_broker.nim
nim c -r test/test_multi_request_broker.nim
```

Tests use `testutils/unittests` (not the stdlib `unittest`).

## Key Dependencies

- **chronos** — Async runtime (`Future`, `async`, `await`, `asyncSpawn`)
- **results** — `Result[T, E]` error handling (no exceptions in public APIs)
- **chronicles** — Structured logging (used in EventBroker for error reporting)
- **std/macros** — All three brokers are Nim macros that generate types and procs

## Architecture

### Code generation pattern

Each broker macro (`EventBroker`, `RequestBroker`, `MultiRequestBroker`) follows the same structure:

1. **Parse** the user-supplied type definition using shared helper `parseSingleTypeDef` in `src/helper/broker_utils.nim`.
2. **Generate** a type section (the value type, handler proc types, broker storage type) and all public API procs (`listen`/`emit`, `setProvider`/`request`/`clearProvider`, etc.).
3. Store state in a **thread-local global** (`{.threadvar.}`) — no locking needed within a single thread.

### BrokerContext system (`src/broker_context.nim`)

`BrokerContext` is a `distinct uint32` used to multiplex independent broker instances on the same thread. `NewBrokerContext()` generates unique IDs via an atomic counter. A global context accessor with an `AsyncLock` is available via `lockGlobalBrokerContext` for serialized cross-module coordination.

### Type handling for non-object types

When a broker type is declared as a native type, alias, or externally-defined type (not an inline `object`/`ref object`), the macros automatically wrap it in `distinct` to prevent overload ambiguity. If the user already wrote `distinct`, it is preserved as-is.

### EventBroker specifics

- Listeners stored in a `Table[uint64, HandlerProc]` per context bucket.
- `emit` snapshots the listener list then calls `asyncSpawn` per listener (fire-and-forget).
- Inline object types get extra `emit` overloads that accept fields directly (e.g. `TypeName.emit(field1 = val1, field2 = val2)`).

### RequestBroker specifics

- Supports two independent signature slots: zero-argument and argument-based.
- `RequestBroker(sync):` generates synchronous procs (`{.gcsafe, raises: [].}`) instead of async ones.
- Provider exceptions are caught and returned as `err(...)`.

### MultiRequestBroker specifics

- Async only (no sync mode).
- Multiple providers per signature; `request()` fans out to all via `allFinished`.
- Fails the entire request if any provider fails.
- Deduplicates identical handler references on registration.

## Coding Conventions

- All source files use `{.push raises: [].}` or equivalent to enforce no-exception boundaries.
- Public async procs use `{.async: (raises: []).}` — errors are communicated through `Result`, not exceptions.
- Generated identifier names are sanitized via `sanitizeIdentName` to be safe Nim identifiers.
- Debug output of generated AST is available via `-d:brokerDebug`compile flags.
