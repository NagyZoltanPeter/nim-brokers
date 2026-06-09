# nim-brokers

What is nim-brokers?
- A type-safe component communication library for Nim, built on top of [chronos](https://github.com/status-im/nim-chronos).
- **Pub/Sub and Request/Response patterns**, with both single-thread and multi-thread variants.
  - Built with simple aim to decouple interface definitions from implementations, and to decouple modules that need to talk to each other without creating direct dependencies. 
- Useful for clean and compile time checked module interface definitions - with no manual wiring or boilerplate.
- Suitable for **Dependency Injection / Inversion of Control (DI/IC)** pattern implementation. 
  - Implementation is runtime configurable and swappable.
  - Easy mocking and testing of components in isolation.
- Out of the box **FFI API** layer for exposing broker-driven nim modules/services as a shared library with to other languages.
  - Write Nim code once and generate **C / C++ / Python / Rust / Go bindings**.
   - No manual plumbing to glue with other languages.
   - Type safe, memory safe and a clean API surface on the foreign language side.
   - The same API interface is available for other Nim modules and for foreign language consumers alike at the same time.
   - A single **CBOR-encoded C ABI** strategy (the historical `native` C-ABI codegen was retired in 3.0.0).
     - The C++, Python, Rust and Go wrapper public surfaces are identical and idiomatic regardless of the CBOR wire format underneath. 

> **Version:** current release is **3.1.1** (see `brokers.nimble`). 
> :exclamation: Current recommended version to use is **3.1.1**.
> Full per-release history and feature notes are in [CHANGELOG.md](CHANGELOG.md).

## Table of Contents

- [nim-brokers](#nim-brokers)
  - [Table of Contents](#table-of-contents)
  - [Presentation slides](#presentation-slides)
  - [Installation](#installation)
  - [Testing](#testing)
  - [Debug](#debug)
      - [Compile-flag reference](#compile-flag-reference)
      - [Examples](#examples)
  - [Types of Brokers](#types-of-brokers)
    - [EventBroker](#eventbroker)
    - [RequestBroker](#requestbroker)
    - [MultiRequestBroker](#multirequestbroker)
    - [BrokerContext](#brokercontext)
  - [Multi-thread support](#multi-thread-support)
    - [RequestBroker (multi-thread)](#requestbroker-multi-thread)
    - [EventBroker (multi-thread)](#eventbroker-multi-thread)
    - [Tuning multi-thread brokers](#tuning-multi-thread-brokers)
  - [Broker FFI API](#broker-ffi-api)
    - [FFI\_API detailed documentation](#ffi_api-detailed-documentation)
    - [Type-support matrix](#type-support-matrix)
    - [FFI API strategy](#ffi-api-strategy)
      - [Torpedo Duel — a richer FFI API example](#torpedo-duel--a-richer-ffi-api-example)
  - [Some more details...](#some-more-details)
    - [Non-Object Types](#non-object-types)
  - [Memory Footprint](#memory-footprint)
    - [EventBroker (single-thread)](#eventbroker-single-thread)
    - [RequestBroker (single-thread, async)](#requestbroker-single-thread-async)
    - [EventBroker(mt) — example](#eventbrokermt--example)
    - [RequestBroker(mt) — example](#requestbrokermt--example)
    - [Comparison](#comparison)
  - [Platform \& Nim Version Support](#platform--nim-version-support)
    - [Windows toolchain requirements](#windows-toolchain-requirements)
  - [License](#license)
  - [Credits](#credits)

## Presentation slides  

[May start with the presentation slides available here...](https://nagyzoltanpeter.github.io/nim-brokers/BrokerDesignPrezi.html).

## Installation

```
nimble install brokers
```

Or add to your `.nimble` file:

```nim
requires "brokers >= 3.1.0"
```

## Testing

```
nimble alltests
```

> inspect with `nimble tasks` to see the full list of test variants (debug/release, orc/refc, multi-threaded, etc).

## Debug

nim-brokers is macro-heavy - better say it generates all the boilerplate around your interfaces and dispatch machinery. 
To inspect the Nim code that the broker macros (and `registerBrokerLibrary`) emit, compile any project that
uses them with `-d:brokerDebug`:

```
nim c -d:brokerDebug ...
```

Every macro expansion is dumped to its own file under
`build/broker_debug/`, rendered back to Nim source for offline
examination. Layout for an FFI library example:

```
build/broker_debug/
  ├── InitializeRequest__RequestBrokerApi.gen.nim
  ├── ShutdownRequest__RequestBrokerApi.gen.nim
  ├── ListDevices__RequestBrokerApi.gen.nim
  ├── DeviceStatusChanged__EventBrokerApi.gen.nim
  ├── ...
  ├── <BrokerType>__RequestBrokerMt.gen.nim   ← underlying MT broker
  ├── <BrokerType>__EventBrokerMt.gen.nim       (one per API broker —
  │                                              the (API) layer wraps it)
  └── <libName>__BrokerLibrary.gen.nim   ← `registerBrokerLibrary` output:
                                           the FFI C-ABI surface,
                                           lifecycle, courier wiring,
                                           dispatch table (~1000 lines
                                           for a non-trivial library)
```

Each file opens with a seven-line header naming the role, the broker
type, and a context note (e.g. `apiName='initialize_request'`). The
rest is pure ASCII Nim source — open in your editor, `diff` against
a previous build, or pipe through `nph` for prettier formatting.

#### Compile-flag reference

| Flag | Effect |
|---|---|
| `-d:brokerDebug` | Enable the dump. |
| `-d:brokerDebugDir=<path>` | Override the output directory (default `build/broker_debug`). |
| `-d:brokerDebugStdout` | *Also* echo the generated AST to stdout — the historical "print to console" behaviour. Default is file-only because the FFI lib stub alone is ~1000 lines and would drown the build log. |

#### Examples

```sh
# 1. Default — dump under build/broker_debug/
nim c -d:BrokerFfiApi -d:brokerDebug --threads:on --app:lib --path:. \
  --outdir:examples/ffiapi/nimlib/build --nimMainPrefix:mylib \
  examples/ffiapi/nimlib/mylib.nim

# 2. Custom dump location (and ALSO echo to console)
nim c -d:brokerDebug -d:brokerDebugDir=/tmp/mylib_ast \
  -d:brokerDebugStdout ...

# 3. Single-file view on demand
cat build/broker_debug/*.gen.nim > all.gen.nim

# 4. Prettier formatting per broker
nph build/broker_debug/<libName>__BrokerLibrary.gen.nim
```

Files are overwritten on rebuild; stale entries from earlier builds
are NOT auto-cleaned. `rm -rf build/broker_debug` before compiling
if you want a fresh snapshot.

## Types of Brokers

### EventBroker

Reactive pub/sub: many emitters → many listeners. Listeners are async procs; events are dispatched as fire-and-forget.

```nim
import brokers/event_broker

# interface definition separated:
EventBroker:
  type GreetingEvent = object
    text*: string



# Usage:

# Register a listener (returns a handle for later removal)
let handle = GreetingEvent.listen(
  proc(evt: GreetingEvent): Future[void] {.async: (raises: []).} =
    echo evt.text
)

# Emit by value
GreetingEvent.emit(GreetingEvent(text: "hello"))

# Emit by fields (inline object types only)
GreetingEvent.emit(text = "hello")

# Remove a single listener
GreetingEvent.dropListener(handle.get())

# Remove all listeners
GreetingEvent.dropAllListeners()
```

### RequestBroker

Single-provider request/response: one provider registers; callers make typed requests. Supports both **async** (default) and **sync** modes.

```nim
import brokers/request_broker

#interface definition separated:
# Async mode (default)
RequestBroker:
  type Greeting = object
    text*: string

  proc signature*(): Future[Result[Greeting, string]] {.async.}
  proc signature*(to: string): Future[Result[Greeting, string]] {.async.}

# Implementation is dynamically set:
Greeting.setProvider(
  proc(): Future[Result[Greeting, string]] {.async.} =
    ok(Greeting(text: "hello"))
)

Greeting.setProvider(
  proc(to: string): Future[Result[Greeting, string]] {.async.} =
    ok(Greeting(text: "hello " & to))
)

# use it from anywhere where the definition is visible:
let res = await Greeting.request()
assert res.isOk()
echo res.get().text  # "hello"

Greeting.clearProvider()
```

```nim
# Sync mode
RequestBroker(sync):
  type Config = object
    value*: string

  proc signature*(): Result[Config, string]

Config.setProvider(
  proc(): Result[Config, string] =
    ok(Config(value: "default"))
)

let res = Config.request()  # no await needed
Config.clearProvider()
```
As an alternative simpler syntax when the return value is single data type you can describe RequestBroker as
```nim
RequestBroker(sync):
  proc PlusOp*(a: int, b: int): Result[int, string]
```
Macro will extend the generated `PlusOp` RequestBroker - name is derived from the proc name.

 RequestBroker support two differnet call signatures in the same broker definition. The signature procs can be overloaded by arity and parameter types, and the generated `request()` proc will dispatch to the correct provider based on the call-site arguments.
> If no `signature` proc is declared, a zero-argument form is generated automatically.

### MultiRequestBroker

Multi-provider fan-out request/response: Multiple providers register; `request()` calls all of them and aggregates the results - (async only). The request fails if any provider fails.

```nim
import brokers/multi_request_broker

MultiRequestBroker:
  type Info = object
    label*: string

  proc signature*(): Future[Result[Info, string]] {.async.}

discard Info.setProvider(
  proc(): Future[Result[Info, string]] {.async.} =
    ok(Info(label: "from-module-a"))
)

discard Info.setProvider(
  proc(): Future[Result[Info, string]] {.async.} =
    ok(Info(label: "from-module-b"))
)

let responses = await Info.request()  # Result[seq[Info], string]
assert responses.get().len == 2

# Remove a specific provider by handle
let handle = Info.setProvider(myHandler)
Info.removeProvider(handle.get())

# Remove all providers
Info.clearProviders()
```

### BrokerContext

Any broker can be scoped to a `BrokerContext` for isolation / sandboxing.
> Listeners registered under different contexts are isolated; emitting to one context does not trigger listeners in another. This is useful for multi-tenant scenarios where you want to keep different modules or users' events separate without needing multiple broker types.

```nim
import brokers/broker_context
import brokers/event_broker

EventBroker:
  type MyEvent = object
    value*: int

let ctxA = NewBrokerContext()
let ctxB = NewBrokerContext()

# Listeners registered under different contexts are isolated
discard MyEvent.listen(ctxA, proc(evt: MyEvent): Future[void] {.async: (raises: []).} =
  echo "A: ", evt.value
)
discard MyEvent.listen(ctxB, proc(evt: MyEvent): Future[void] {.async: (raises: []).} =
  echo "B: ", evt.value
)

MyEvent.emit(ctxA, MyEvent(value: 1))  # only context A listener fires
MyEvent.emit(ctxB, MyEvent(value: 2))  # only context B listener fires

MyEvent.dropAllListeners(ctxA)
MyEvent.dropAllListeners(ctxB)
```

When no `BrokerContext` argument is passed, the `DefaultBrokerContext` is used.

A global context lock is available via `lockGlobalBrokerContext` for serialized cross-module coordination within `chronos` async procs.

s
`BrokerInterface` and `BrokerImplement` are **syntactic sugar over the same `EventBroker` and `RequestBroker` macros** documented above. Inner broker blocks are re-emitted verbatim — you can use any broker variant (`EventBroker`, `RequestBroker(sync)`, `RequestBroker(mt)`, etc.) inside an interface body. The one exception is `BrokerInterface(API, IFace):`, which auto-propagates `(API)` to every inner broker. The OOP layer adds interface/implementation separation, per-instance state, deterministic lifecycle, and dependency injection without changing the underlying broker machinery.

The key idea: **define your communication contract once as an interface, implement it separately, swap implementations at runtime.** The macros generate all the boilerplate — broker definitions, public request procs, provider wiring, instance isolation, and cleanup.

**`BrokerInterface`** declares the *contract*: a `ref object` base type grouping related events and requests. For each request verb it generates a **public proc that tunnels through the broker** (`proc greet(self, …) = Greet.request(self.brokerCtx, …)`) — a plain proc, not a `{.base.}` virtual method, so every call (including a direct `g.greet(…)` or a base-typed `IGreeter(g).greet(…)`) routes through the broker dispatch path. It also generates an instance-scoped event facade (`self.emit` / `self.listen`) and a built-in factory broker for DI (`provideFactory` / `create`).

**`BrokerImplement`** provides the *fulfillment*: it wires a concrete `ref object of IFace` to the interface. The user authors a natural `proc new` that returns a **bare** instance; the macro generates `Impl.create(args...)` (allocates a fresh `BrokerContext`, calls `new`, runs the optional `init(self)` hook, auto-registers per-instance providers), `Impl.createUnderContext(ctx, args...)` (same but adopts an external `BrokerContext` — used by the FFI lane and sub-instance facades), and `close()` (deterministic cleanup of providers + listeners — mandatory under `--mm:refc` to break the closure cycle, recommended under `--mm:orc`). Each `method` body becomes a private `<verb>Impl` proc invoked only by the provider closure.

Because method calls tunnel through the broker, **a test can swap a broker's provider for one context and the direct method call honors it** — `Greet.withMockProvider(ctx, mock): body` (plus `getCurrentProvider` / `replaceProvider`) scopes the swap and restores it afterwards.

```nim
import brokers/broker_interface
import brokers/broker_implement

# --- Interface (the contract) ---
BrokerInterface(IGreeter):
  EventBroker:
    type Greeted = object
      who: string

  RequestBroker:
    proc greet(name: string): Future[Result[string, string]] {.async.}

# --- Implementation (the fulfillment) ---
type GreeterImpl = ref object of IGreeter
  prefix: string

BrokerImplement GreeterImpl of IGreeter:
  proc new(T: typedesc[GreeterImpl], prefix: string): GreeterImpl =
    GreeterImpl(prefix: prefix)            # bare instance; create() wires it

  method greet(
      self: GreeterImpl, name: string
  ): Future[Result[string, string]] {.async.} =
    ok(self.prefix & name)

# --- Usage ---
let a = GreeterImpl.create(prefix = "hello ")
let b = GreeterImpl.create(prefix = "hi ")

# Each instance has its own BrokerContext — fully isolated.
# The call tunnels through the broker (Greet.request) — no direct vtable call.
assert (waitFor a.greet("alice")).value == "hello alice"
assert (waitFor b.greet("alice")).value == "hi alice"

# Testing: swapping the provider is honored by the direct method call.
Greet.withMockProvider(a.brokerCtx,
  proc(name: string): Future[Result[string, string]] {.async.} =
    ok("MOCK<" & name & ">")):
  assert (waitFor a.greet("alice")).value == "MOCK<alice>"
assert (waitFor a.greet("alice")).value == "hello alice"  # restored

# DI: consumer depends only on the interface
IGreeter.provideFactory(proc(): Result[IGreeter, string] =
  ok(GreeterImpl.create(prefix = "default:")))
let svc = IGreeter.create().value
assert (waitFor svc.greet("x")).value == "default:x"

a.close()  # deterministic cleanup; b unaffected
b.close()
```

For FFI libraries, `BrokerInterface(API, IFace):` propagates the `(API)` marker to all inner brokers automatically. The generated wrapper classes follow the same pattern across all languages — the main interface becomes the library class (`Hierlib` in C++ / Python / Rust / Go), and sub-interfaces become independent typed wrapper classes (`Widget`) with their own methods and RAII-style lifetime management. The OOP structure is an *authoring* concern — foreign consumers see the same typed API surface regardless of whether the Nim side uses flat or OOP brokers.

Full documentation — use cases, DI patterns, hierarchical sub-instances, FFI wrapper class layout, memory model notes, and comparison with flat brokers — is in **[doc/OOP_Brokers.md](doc/OOP_Brokers.md)**.

## Multi-thread support

With `(mt)` variants, nim-brokers supports cross-thread communication with the same type-safe, decoupled interface as the single-thread versions. Since v2.0.0 the multi-thread implementation dispatches cross-thread work over a **lock-free Vyukov MPSC ring + a pre-allocated payload slab** (plus a response-slot pool for `RequestBroker(mt)`), woken by one shared `ThreadSignalPtr` per thread. There is **no `Channel[T]` on the hot path** — payloads are encoded into a refcounted slab cell, the ring carries the cell index, and the listener decodes in place. Same-thread calls bypass the ring entirely for near-zero overhead. See [doc/MT_BROKER_REFACTOR_RETROSPECTIVE.md](doc/MT_BROKER_REFACTOR_RETROSPECTIVE.md) for the design rationale and benchmark deltas.

### RequestBroker (multi-thread)

Cross-thread request/response. The provider runs on the thread that called `setProvider`; requests from **any** thread in the process are routed to it via the ring+slab+pool dispatch and a shared per-thread signal. Sizing (ring depth, slab capacity, response-slot count, max payload bytes) is determined at compile time — type-driven defaults are applied unless overridden via kwargs/presets; see "Tuning multi-thread brokers" below.
```nim
import std/atomics, std/threads
import chronos
import brokers/request_broker

RequestBroker(mt):
  type Weather = object
    city*: string
    tempC*: float

  proc signature*(city: string): Future[Result[Weather, string]] {.async.}

var done: Atomic[bool]

proc worker() {.thread.} =
  let res = waitFor Weather.request("Berlin")
  doAssert res.isOk()
  done.store(true)

# ── Provider thread (main) ──────────────────────────
proc main() {.async.} =
  initAtomic(done, false)

  doAssert Weather.setProvider(
    proc(city: string): Future[Result[Weather, string]] {.async.} =
      ok(Weather(city: city, tempC: 21.5))
  ).isOk()

  var t: Thread[void]
  t.createThread(worker)
  while not done.load():
    await sleepAsync(chronos.milliseconds(1))
  t.joinThread()
  Weather.clearProvider()

waitFor main()
```

Compile with `--threads:on` (and `--mm:orc` or `--mm:refc`).

**When to choose multi-thread mode:**

- Your provider lives on a dedicated thread (e.g. main/UI loop) and workers need to query it.
- You want a typed, decoupled interface across thread boundaries without manual channel wiring.
- Sandboxing: multiple independent contexts (`BrokerContext`) served by different threads.

**Cross-thread request timeout:**

Cross-thread requests have a configurable timeout (default: 5 seconds). If the provider thread is unresponsive, `request()` returns `err` instead of hanging. Same-thread requests are unaffected.

```nim
Weather.setRequestTimeout(chronos.seconds(2))  # shorten timeout
echo Weather.requestTimeout()                   # 2 seconds
```

**Performance considerations:**

- **Same-thread path** is a direct provider call through threadvar state — zero ring/slab traffic.
- **Cross-thread path** reserves a response slot from the pool, encodes the request into a slab cell, enqueues the cell index on the ring, and signals the provider. No per-call shared-heap allocation — the slab and pool are pre-sized at init. Refc and ORC are now close in performance (the old `Channel[T]` deep-copy gap is gone).
- The provider serves requests sequentially on its event loop; throughput is bounded by handler execution time.
- A **bounded ring/pool can return `err(...)` on overflow** (visible failure mode); size them via kwargs/presets if the workload is bursty. See [doc/MT_BROKER_CONFIG.md](doc/MT_BROKER_CONFIG.md).
- See the perf table in [doc/MT_BROKER_REFACTOR_RETROSPECTIVE.md](doc/MT_BROKER_REFACTOR_RETROSPECTIVE.md) — up to **7.4× throughput** / **270× lower latency** vs. the v1.x `Channel[T]` design under refc.

See [Multi-Thread RequestBroker](doc/MultiThread_RequestBroker.md) for architecture diagrams, call sequences, and memory layout details. Run `nimble perftest` for benchmarks.

### EventBroker (multi-thread)

Cross-thread pub/sub (fire-and-forget). Listeners can be registered on **any** thread; events emitted from **any** thread are broadcast to all registered listeners. Same-thread delivery uses `asyncSpawn` (no ring traffic). Cross-thread delivery encodes the event **once** into a slab cell, refcounts it to the listener count, and enqueues the cell index on each listener-thread's ring; the listener thread is woken by its shared per-thread `ThreadSignalPtr`. Zero per-emit shared-heap allocation, zero OS fds per broker type.

```nim
import brokers/event_broker
import std/atomics

EventBroker(mt):
  type Alert = object
    level*: int
    message*: string

var doneFlag {.global.}: Atomic[bool]

proc worker() {.thread.} =
  waitFor Alert.emit(Alert(level: 1, message: "from worker"))
  doneFlag.store(true, moRelaxed)

# ── Listener on main thread ────────────────────────────
proc main() {.async.} =
  let handle = Alert.listen(
    proc(evt: Alert): Future[void] {.async: (raises: []).} =
      echo "Alert [", evt.level, "]: ", evt.message
  )
  doAssert handle.isOk()

  var t: Thread[void]
  t.createThread(worker)
  while not doneFlag.load(moRelaxed):
    await sleepAsync(chronos.milliseconds(1))
  t.joinThread()
  Alert.dropAllListeners()

waitFor main()
```

Compile with `--threads:on` (and `--mm:orc` or `--mm:refc`).

**Key differences from single-thread EventBroker:**

- `emit()` is **async** — use `await` in async contexts or `waitFor` from `{.thread.}` procs.
- `dropListener` must be called from the **registering thread** (enforced at runtime).
- `dropAllListeners` can be called from **any thread** — sends shutdown to all listener threads and drains in-flight listener tasks before cleanup.

**Performance considerations:**

- **Same-thread path** bypasses the ring entirely — events dispatch directly via `asyncSpawn`.
- **Cross-thread path**: one slab encode + one refcount initialise to `N_listeners`, then one ring enqueue per listener-thread, then a single `fireBrokerSignal` per listener-thread. Under v2.0.0 this yields **~788 K evt/s** (refc) / **~511 K evt/s** (orc) on the 5×500×512 B benchmark — see [retrospective](doc/MT_BROKER_REFACTOR_RETROSPECTIVE.md).
- Fan-out: **one slab cell, atomically refcounted** — no per-listener payload copy. One ring per (BrokerContext, listener-thread) pair; all broker types on a thread share one `ThreadSignalPtr`.
- **Bounded ring** can return `err(...)` on overflow (new visible failure mode vs. unbounded `Channel[T]`). Size via kwargs/presets — see [doc/MT_BROKER_CONFIG.md](doc/MT_BROKER_CONFIG.md).
- For high-throughput scenarios, prefer `--mm:orc` and `-d:release`.

See [Multi-Thread EventBroker](doc/MultiThread_EventBroker.md) for architecture diagrams and memory layout details. Run `nimble perftest` for benchmarks.

### Tuning multi-thread brokers

Both `EventBroker(mt)` and `RequestBroker(mt)` accept optional kwargs to
size the cross-thread dispatch ring, payload slab, and (for requests)
the response slot pool. Sensible defaults are auto-selected from the
broker's type shape — see the type-driven sizing table — but bursty,
large-payload, or memory-constrained deployments will want to override.

```nim
# Wide ring + slab for bursty broadcast; uses a built-in preset.
EventBroker(mt, preset = fastBurst, maxPayloadBytes = 1024):
  type WireEvent = object
    payload*: seq[byte]

# Memory-constrained, fully manual:
RequestBroker(mt, queueDepth = 16, responseSlots = 8,
              maxResponseBytes = 512):
  type LedState = object
  proc query*(id: uint8): Future[Result[LedState, string]] {.async.}
```

Every MT broker callsite emits a compile-time `hint` line showing the
resolved capacity values, their origin (`default` / `kwarg` /
`preset:<name>` / `auto:<reason>`), and an idle-RAM estimate — so you
can see at build time what the broker reserves.

- [doc/MT_BROKER_CONFIG.md](doc/MT_BROKER_CONFIG.md) — full reference:
  knobs, presets, type-driven defaults, compile-time inspection,
  failure-mode troubleshooting.
- [doc/MT_BROKER_REFACTOR_RETROSPECTIVE.md](doc/MT_BROKER_REFACTOR_RETROSPECTIVE.md)
  — design rationale, perf comparison (Channel[T] vs ring+slab+pool),
  and the memory-footprint mitigation strategy.

## Broker FFI API

nim-brokers also includes a macro-based FFI API layer for exposing broker-shaped API as a shared library with generated C, C++, and optional Python / Rust / Go bindings.

At a high level:

- `RequestBroker(API)` and `EventBroker(API)` expose broker requests and events through the generated CBOR C ABI (the fixed 11-function surface), callable from C and from every generated wrapper.
  - On Nim level, the `API` block is just a normal multi-thread broker definition
      - multi-request brokers are not supported on API. 
- `registerBrokerLibrary` generates the library lifecycle exports, context registry, startup threads, and wrapper artifacts.
- The generated library uses a two-thread runtime model per created context:
  - a processing thread for request providers
  - a delivery thread for event listener registration and foreign-language callbacks

The process-wide runtime init and per-context lifecycle are intentionally separate:

- `mylib_createContext()` creates one broker-backed library context and performs any required one-time runtime initialization internally.
- `InitializeRequest` is the broker request used for post-create configuration.
- `ShutdownRequest` is the broker request used for orderly application teardown during shutdown.

For API events, the generated C ABI includes both the emitting `ctx` and an
opaque `userData` pointer in the callback signature. 
The generated C++ wrapper builds on that with an owner-aware dispatcher template: public C++ event callbacks receive `Mylib& owner` as their first argument, callback exceptions are swallowed before they can cross the C boundary, and the wrapper is intentionally non-copyable and non-movable so callback identity stays stable.

If you need multiple wrapper instances in a container, store
`std::unique_ptr<Mylib>` rather than `Mylib` values directly.

Build the example shared library with:

```sh
nimble buildFfiExample
```

Generate other wrappers as well with:

```sh
nimble buildFfiExamplePy / buildFfiExampleRust / buildFfiExampleGo
```

Run the examples with:

```sh
nimble runFfiExampleCpp
nimble runFfiExamplePy
nimble runFfiExampleRust
nimble runFfiExampleGo
```

### FFI_API detailed documentation

... and guidance is available in the [FFI API document](doc/FFI_API.md) which covers:
Architecture, threading behavior, lifecycle requirements, generated API surface, and build guidance.

### Type-support matrix

[Type-support matrix](doc/TYPESUPPORT.md) is available in a separate document.

For the authoritative reference on which Nim type patterns are supported in each wrapper (C / C++ / Python / Rust / Go), with footnoted defects, recommended idioms, and a worked example.

### FFI API strategy

The FFI surface is **CBOR-only**. The historical "native" C-ABI codegen
was retired (see `doc/CBOR_Refactoring.md`); the only build flag is now
`-d:BrokerFfiApi`.

The CBOR strategy serializes all transmittable data into CBOR blobs at the
ABI boundary and decodes / encodes on the wrapper side. Benefits over the
old native path: reduced memory allocations, a single fixed ABI shape that
ports cleanly across languages with CBOR support, and the ability to
transmit complex structs / collections without a per-type C struct.

Every library collapses to the same fixed 11-function C ABI plus a single
event-callback typedef, with CBOR as the on-wire format. Wrappers carry
the typed surface and decode / encode through language-specific CBOR
libraries like `jsoncons` (C++), `cbor2` (Python), `ciborium` (Rust), or
`github.com/fxamacker/cbor` (Go). Buffer ownership rule: every `void*`
crossing the ABI is allocated by Nim and freed by Nim.

C++ wrapper is always generated; Python / Rust / Go wrappers are opt-in
via `-d:BrokerFfiApiGenPy` / `-d:BrokerFfiApiGenRust` / `-d:BrokerFfiApiGenGo`.

> :exclamation: The same example source files can be compiled against either generated header with no changes!


#### Torpedo Duel — a richer FFI API example

The `examples/torpedo/` directory contains a full game example that pushes the
Broker FFI API beyond a minimal hello-world.

One Nim shared library (`torpedolib`) hosts **two independent contexts** in the
same Python process — one per player. After a short bootstrap phase (create,
initialize, place fleets, link opponents), the foreign app calls
`StartGameRequest` on one side and **steps back entirely**. From that point the
two captains exchange volleys autonomously inside Nim through cross-context
`VolleyEvent` listeners, while Python only observes events and polls public
board snapshots for its text UI.

This demonstrates several things that a trivial example cannot:

- **Multi-context isolation** — two active contexts share the same dylib, each
  with its own processing thread, delivery thread, and `Captain` state object.
- **Cross-context native listeners** — `EventBroker(API)` events are not just
  a foreign callback surface; the same `VolleyEvent` type serves as the
  internal protocol between linked contexts *and* as the observable stream
  delivered to FFI app.
- **Object-oriented state management** — all per-player state lives in a
  `Captain` ref object, created by `InitializeCaptainRequest` and torn down by
  `ShutdownRequest`. Only two threadvars remain per processing thread.
- **Callback lifetime safety** — the example shows the correct shutdown
  sequence: unregister all event listeners *before* the context manager calls
  `shutdown()`, preventing use-after-free on ctypes function pointers.
- **Deterministic replays** — identical seeds produce identical games, making
  the example useful for regression testing.

Build and run from the repository root:

```sh
nimble runTorpedoExampleCpp
nimble runTorpedoExamplePy
nimble runTorpedoExampleRust
nimble runTorpedoExampleGo
```

See [`examples/torpedo/DESIGN.md`](examples/torpedo/DESIGN.md) for the full
architecture, sequence diagrams, and API surface reference.


## Some more details...

### Non-Object Types

All three brokers support native types, aliases, and externally-defined types. These are automatically wrapped in `distinct` to prevent overload ambiguity. If the type is already `distinct`, it is preserved as-is.

```nim
RequestBroker(sync):
  type Counter = int  # exported as `distinct int`

Counter.setProvider(proc(): Result[Counter, string] = ok(Counter(42)))
let val = int(Counter.request().get())  # unwrap with cast
```

## Memory Footprint

Single-thread brokers are pure threadvar — no shared memory, no locks, no channels. Multi-thread brokers use `createShared` for global state (GC-independent, safe under both `--mm:orc` and `--mm:refc`).

### EventBroker (single-thread)

**Scenario:** One `BrokerContext` (default) with 3 listeners, plus a second context `ctxA` with 1 listener.

```
Thread-local (GC-managed, per thread):
  gMyEventBroker: ref object            ~16 bytes (ref header + pointer)
    buckets: seq[CtxBucket]             ~24 bytes (seq header)

    buckets[0]:  (DefaultBrokerContext)
      brokerCtx: BrokerContext           ~8 bytes
      listeners: Table[uint64, proc]     ~64 bytes (3 entries: id→closure ptr)
      nextId: uint64                     ~8 bytes
      inFlight: seq[Future[void]]        ~24 bytes (seq header, tracks active futures)

    buckets[1]:  (ctxA)
      brokerCtx: BrokerContext           ~8 bytes
      listeners: Table[uint64, proc]     ~48 bytes (1 entry)
      nextId: uint64                     ~8 bytes
      inFlight: seq[Future[void]]        ~24 bytes

Total: ~248 bytes for 2 contexts, 4 listeners.
```

**Key points:**
- Everything lives in a single `{.threadvar.}` — zero shared memory, zero locks, zero OS resources.
- The `DefaultBrokerContext` bucket is always pre-allocated at index 0 (fast path: no scan needed).
- Non-default context buckets are created on first `listen` and removed when the last listener is dropped.
- Each listener costs one `Table` entry (~16 bytes for key + closure pointer).
- `emit()` snapshots the callback list and dispatches via `asyncSpawn` — no allocation beyond the futures themselves.

### RequestBroker (single-thread, async)

**Scenario:** One `BrokerContext` (default) with both a zero-arg and a with-args provider.

```
Thread-local (GC-managed, per thread):
  gWeatherBroker: object                  (value type, not ref)
    providersNoArgs: seq[(BrokerContext, proc)]    ~24 bytes (seq header)
      [0]: (DefaultBrokerContext, nil)             ~16 bytes (pre-allocated slot)

    providersWithArgs: seq[(BrokerContext, proc)]  ~24 bytes (seq header)
      [0]: (DefaultBrokerContext, handler)         ~16 bytes

Total: ~80 bytes for 1 context, 1 provider signature.
```

**Key points:**
- Pure threadvar — no heap allocation beyond the `seq` buffers, no shared memory.
- `DefaultBrokerContext` is always pre-allocated at index 0 with a nil handler.
- `setProvider` replaces the handler in-place; `clearProvider` sets it back to nil.
- Additional `BrokerContext` entries append to the seq (~16 bytes each).
- `request()` is a direct proc call through the stored closure — zero channel overhead, zero allocation per call.
- `RequestBroker(sync)` has the same layout but handler procs return `Result[T, string]` instead of `Future[Result[T, string]]`.

### EventBroker(mt) — example

**Scenario:** One `BrokerContext` (default). Thread A emits and has one listener. Thread B has two listeners. Thread C has one listener.

> Sizes below reflect the v2.0.0 ring+slab design. `queueDepth` (ring slots),
> `slabCapacity` (cells), and `maxPayloadBytes` (cell size) are resolved at
> compile time from kwargs / preset / type-driven defaults — the values shown
> are illustrative. The exact resolved numbers are printed as a compile-time
> `hint` at every `EventBroker(mt)` call site.

```
Shared memory (process lifetime), per (broker, ctx, listener-thread):
  VyukovMpscRing[uint32]   ring header + queueDepth * uint32 slots
                            (lock-free, pure shared memory, no OS fds)
  PayloadSlab              slabCapacity * (maxPayloadBytes + cell header)
                            (pre-allocated bytes — no per-emit alloc)
  Bucket entry             (Default, listener-threadId, threadGen, active,
                            ring*, slab*, hasListeners)
  Global bucket array      grows as needed; protected by an init/teardown Lock

Per-thread (one-time, shared by ALL broker types on that thread):
  ThreadSignalPtr          ~2 OS fds each (macOS: socketpair) — shared by
                            every (mt) broker type on this thread
  brokerDispatchLoop       one async Future per thread that drains all
                            registered poll fns on the shared signal

Threadvar (per listener thread, GC-managed):
  tvCtxs[Default], tvHandlers[{id → closure}], tvNextIds[next]
   — only the closure table is GC-managed; payloads never enter the GC heap

Total: dominated by `slabCapacity * maxPayloadBytes` per listener-thread bucket
(fixed at compile time), plus three `ThreadSignalPtr`s for thread A/B/C.
```

**Key points:**
- Ring + slab are allocated **per (BrokerContext, listener-thread)** pair — not per listener. Thread B's two listeners share one ring and one slab; the payload is encoded once and refcounted to `N_listeners`.
- Ring storage is pure shared memory — no `Channel[T]`, **no OS fds**.
- The `ThreadSignalPtr` (which holds the OS fd) is **shared** across all broker types on a thread. Adding more broker types costs zero additional fds.
- `brokerDispatchLoop`: a single shared async coroutine per thread wakes on the shared signal and drains all registered poll fns via the ring's non-blocking `tryDeque`.
- Each bucket includes a `threadGen: uint64` field to disambiguate reused threadvar addresses across thread lifetimes, and an `active: bool` flag.
- Emitter threads allocate **zero shared-heap memory per emit** — `emit()` acquires the lock, snapshots target buckets, encodes the payload **once** into a slab cell, sets the refcount, enqueues the cell index on each listener's ring, and fires each target thread's shared signal.
- **Bounded ring:** if a listener thread's ring is full, the emitter sees overflow on enqueue (visible failure mode — explicit, not silently buffered). Size via `queueDepth` / preset / kwarg.
- Buckets and slabs persist across `dropListener`/`listen` cycles (capacity is reused).

### RequestBroker(mt) — example

**Scenario:** One `BrokerContext` (default). Thread A provides and also requests (same-thread). Threads B and C request cross-thread.

> Sizes below reflect the v2.0.0 ring+slab+pool design. `queueDepth`,
> `slabCapacity`, `maxPayloadBytes`, `responseSlots`, and `maxResponseBytes`
> are resolved at compile time; the values are printed as a compile-time
> `hint` at the `RequestBroker(mt)` call site.

```
Shared memory (process lifetime), per (broker, ctx):
  VyukovMpscRing[uint32]    ring header + queueDepth slots (request side)
  PayloadSlab               slabCapacity * (maxPayloadBytes + header)
  ResponseSlotPool          responseSlots * (maxResponseBytes + slot header)
                             (reserved per in-flight request, freed on decode)
  Bucket entry              (Default, providerThreadId, threadGen, ring*,
                             slab*, pool*)
  Global bucket array       grows as needed; protected by an init/teardown Lock
  Timeout var (Duration)    ~8 bytes — applies only to cross-thread requests

Per-thread (one-time, shared by ALL broker types on that thread):
  ThreadSignalPtr            ~2 OS fds (macOS: socketpair) — shared across
                             every (mt) broker type on the thread

Threadvar (provider thread A only):
  tvCtxs[Default], tvHandlers[handler]

Per-request (cross-thread only, transient — no shared-heap alloc per call):
  One slot in ResponseSlotPool reserved at request issue, returned on decode.
  On timeout: the slot is sealed and freed deterministically on the requester
  side; the provider's eventual write into a sealed slot is a no-op (safe).
```

**Per-request cost:**

| Path | Allocation per call | Notes |
|------|---------------------|-------|
| Same-thread (Thread A → A) | Zero | direct provider call through threadvar |
| Cross-thread (Thread B → A) | Zero (pool + slab pre-sized at init) | request encoded into a slab cell, reply written into a reserved pool slot |

**Key points:**
- Same-thread requests have **zero ring/slab traffic** — the provider handler is called directly from threadvar.
- Cross-thread requests do **not** allocate per call: a slab cell holds the request payload, a response-pool slot holds the reply. Both come from pre-sized pools. On timeout the pool slot is reclaimed deterministically (no leak, no OS fd).
- The request ring is shared — all requester threads enqueue into the same MPSC ring. A shared `brokerDispatchLoop` on the provider thread drains it via the ring's `tryDeque`.
- Adding a second `BrokerContext` on the same provider thread costs one additional bucket + ring + slab + pool — exact size driven by the compile-time config.
- **Bounded resources can return `err(...)` on overflow**: ring full → enqueue failure; pool exhausted → no free response slot. Tune via `queueDepth` / `responseSlots` / preset.

### Comparison

| | EventBroker | RequestBroker | EventBroker(mt) | RequestBroker(mt) |
|---|---|---|---|---|
| Storage | threadvar only | threadvar only | createShared + threadvars | createShared + threadvars |
| Shared memory | None | None | Bucket array + Lock + ring + slab (per listener-thread) | Bucket array + Lock + ring + slab + response-slot pool (per context) |
| Dispatch primitive | direct asyncSpawn | direct call | Vyukov MPSC ring (cell idx) + refcounted slab cell | Vyukov MPSC ring (cell idx) + slab + response-slot pool |
| Per-call cost | Zero | Zero | Zero shared-heap alloc; one slab encode + N ring enqueues | Zero shared-heap alloc; one slab encode + one pool slot reservation |
| OS resources | None | None | **One** `ThreadSignalPtr` per thread (shared by all broker types) | **One** `ThreadSignalPtr` per thread (shared) |
| Baseline per context | ~100 bytes | ~16 bytes | Compile-time-sized: ring + slab (printed as hint) | Compile-time-sized: ring + slab + pool (printed as hint) |
| Overflow behaviour | n/a | n/a | enqueue failure → emitter sees `err`/drop (visible) | enqueue failure or pool exhaustion → `err` (visible) |
| Intentional leaks | None | None | None — slab cells return via refcount | None — pool slots are sealed + reclaimed on timeout |

## Platform & Nim Version Support

Every supported platform × Nim version × memory manager combination
is CI-green on every PR. The only build floor is **Nim ≥ 2.2.0**
(2.0.x had upstream refc bugs we don't work around). One caveat
applies on Windows + refc: don't call Nim allocators from your own
`RegisterWaitForSingleObject` callbacks — see
[LIMITATION.md](doc/LIMITATION.md) §2.2 for the hazard analysis.

Recommended baseline: **Nim ≥ 2.2.10 with `--mm:orc`** for the
smoothest experience; **Nim ≥ 2.2.4 + refc** also fully supported on
every platform.

The companion [`doc/design/LESSONS_LEARNED.md`](doc/design/LESSONS_LEARNED.md)
preserves the diagnostic history of the issues that closed during
the Round-2 retirement: stdlib `Channel[T]` allocator races, chronos
Future allocator pressure under high-frequency FFI RPC,
provider-thread teardown ordering, and the Windows-refc-chronos
hazard that turned out narrower than feared.

### Windows toolchain requirements

The Broker FFI API requires LLVM clang and Ninja on `PATH` for FFI builds
on Windows (the bundled MinGW `gcc` mismatches the cmake-side MSVC CRT and
produces cross-heap crashes). When running the AddressSanitizer tasks,
`clang_rt.asan_dynamic-x86_64.dll` from
`C:\Program Files\LLVM\lib\clang\<ver>\lib\windows\` must also be on
`PATH`; the `memcheck_ci.yml` workflow handles this for CI. See
LIMITATION.md → §3 for the toolchain rationale.

## License

MIT

## Credits

`nim-brokers` builds on the work of two excellent open-source projects:

- [**chronos**](https://github.com/status-im/nim-chronos) — the asynchronous
  runtime that powers every broker. All async dispatch, `Future[T]`,
  `ThreadSignalPtr`, and the cooperative scheduling model used by the
  multi-thread brokers and the FFI API runtime come from chronos.
- [**jsoncons**](https://github.com/danielaparker/jsoncons) — the header-only
  C++ JSON / CBOR library used by the generated CBOR-mode C++ wrappers
  (`*.hpp`) to encode and decode the wire format produced by the
  CBOR FFI ABI. Vendored as a git submodule under `vendor/jsoncons` and
  pinned to a tagged release; fetch it with `nimble fetchVendor`.

Many thanks to the maintainers and contributors of both projects.
