# nim-brokers

Type-safe, thread-local, decoupled messaging patterns for Nim, built on top of [chronos](https://github.com/status-im/nim-chronos).

nim-brokers provides three compile-time macro-generated broker patterns that enable event-driven and request-response communication between modules without direct dependencies.

## Presentation slides  

[May start with the presentation slides available here...](https://nagyzoltanpeter.github.io/nim-brokers/BrokerDesignPrezi.html).

## Installation

```
nimble install brokers
```

Or add to your `.nimble` file:

```nim
requires "brokers >= 0.1.0"
```

## Broker Types

### EventBroker

Reactive pub/sub: many emitters → many listeners. Listeners are async procs; events are dispatched via `asyncSpawn` (fire-and-forget).

```nim
import brokers/event_broker

EventBroker:
  type GreetingEvent = object
    text*: string

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

Single-provider request/response. One provider registers; callers make typed requests. Supports both **async** (default) and **sync** modes.

```nim
import brokers/request_broker

# Async mode (default)
RequestBroker:
  type Greeting = object
    text*: string

  proc signature*(): Future[Result[Greeting, string]] {.async.}
  proc signature*(lang: string): Future[Result[Greeting, string]] {.async.}

Greeting.setProvider(
  proc(): Future[Result[Greeting, string]] {.async.} =
    ok(Greeting(text: "hello"))
)

let res = await Greeting.request()
assert res.isOk()
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

If no `signature` proc is declared, a zero-argument form is generated automatically.

### MultiRequestBroker

Multi-provider fan-out request/response (async only). Multiple providers register; `request()` calls all of them and aggregates the results. The request fails if any provider fails.

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

### RequestBroker (multi-thread)

Cross-thread request/response. The provider runs on the thread that called `setProvider`; requests from **any** thread in the process are routed to it via a zero-fd channel and a shared per-thread signal. Same-thread requests bypass channels entirely for near-zero overhead.

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
- You need multiple independent contexts (`BrokerContext`) served by different threads.

**Cross-thread request timeout:**

Cross-thread requests have a configurable timeout (default: 5 seconds). If the provider thread is unresponsive, `request()` returns `err` instead of hanging. Same-thread requests are unaffected.

```nim
Weather.setRequestTimeout(chronos.seconds(2))  # shorten timeout
echo Weather.requestTimeout()                   # 2 seconds
```

**Performance considerations:**

- **Same-thread path** adds only a mutex + threadvar scan (~25 µs debug, sub-microsecond release).
- **Cross-thread path** allocates a one-shot response channel per request (~187 µs debug / ~2-5 µs release with ORC). `--mm:refc` is ~2-3x slower due to deep-copy semantics on `Channel[T].send`.
- The provider serves requests sequentially on its event loop; throughput is bounded by handler execution time.
- For high-throughput scenarios (>10K req/s), consider batching at the application level or using `--mm:orc`.

See [Multi-Thread RequestBroker](doc/MultiThread_RequestBroker.md) for architecture diagrams, call sequences, and memory layout details. Run `nimble perftest` for benchmarks.

### EventBroker (multi-thread)

Cross-thread pub/sub (fire-and-forget). Listeners can be registered on **any** thread; events emitted from **any** thread are broadcast to all registered listeners. Same-thread delivery uses `asyncSpawn` (no channel); cross-thread delivery uses a `Channel[T]` per listener-thread plus a shared per-thread signal — zero OS file descriptors per broker type.

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

- **Same-thread path** bypasses channels entirely — events dispatch directly via `asyncSpawn`.
- **Cross-thread path** sends to each listener thread's `Channel[T]` then wakes the shared signal (~20-160 µs debug, sub-millisecond release).
- Broadcast fan-out: one `Channel[T]` per (BrokerContext, listener-thread) pair; all broker types on a thread share one `ThreadSignalPtr`.
- For high-throughput scenarios, prefer `--mm:orc` and `-d:release`.

See [Multi-Thread EventBroker](doc/MultiThread_EventBroker.md) for architecture diagrams and memory layout details. Run `nimble perftest` for benchmarks.

## Broker FFI API

nim-brokers also includes a macro-based FFI API layer for exposing broker-driven services as a shared library with generated C, C++, and optional Python bindings.

At a high level:

- `RequestBroker(API)` and `EventBroker(API)` generate C-callable request and event registration functions.
- `registerBrokerLibrary` generates the library lifecycle exports, context registry, startup threads, and wrapper artifacts.
- The generated library uses a two-thread runtime model per created context:
  - a processing thread for request providers
  - a delivery thread for event listener registration and foreign-language callbacks

The process-wide runtime init and per-context lifecycle are intentionally separate:

- `mylib_createContext()` creates one broker-backed library context and performs any required one-time runtime initialization internally.
- `InitializeRequest` is the broker request used for post-create configuration.
- `ShutdownRequest` is the broker request used for orderly application teardown during shutdown.

For API events, the generated C ABI now includes both the emitting `ctx` and an
opaque `userData` pointer in the callback signature. The generated C++ wrapper
builds on that with an owner-aware dispatcher template: public C++ event
callbacks receive `Mylib& owner` as their first argument, callback exceptions
are swallowed before they can cross the C boundary, and the wrapper is
intentionally non-copyable and non-movable so callback identity stays stable.

If you need multiple wrapper instances in a container, store
`std::unique_ptr<Mylib>` rather than `Mylib` values directly.

Build the example shared library with:

```sh
nimble buildFfiExample
```

Generate the Python wrapper as well with:

```sh
nimble buildFfiExamplePy
```

Run the examples with:

```sh
nimble runFfiExampleC
nimble runFfiExampleCpp
nimble runFfiExamplePy
```

See [Broker FFI API](doc/Broker_FFI_API.md) for architecture, threading behavior, lifecycle requirements, generated API surface, and build guidance.

### CBOR FFI strategy

The default FFI strategy emits a per-request typed C ABI (struct + free
helper per type). The CBOR strategy — selected with
`-d:BrokerFfiApiCBOR` — collapses every library to the same fixed
10-function ABI plus a single event-callback typedef, with CBOR as the
on-wire format. Wrappers carry the typed surface (typed `Lib::*`
methods on C++, `IntEnum` + `dataclass` on Python) and decode/encode
through `jsoncons::cbor` (C++) or `cbor2` (Python). Buffer ownership
rule: every `void*` crossing the ABI is allocated by Nim and freed by
Nim.

Each library also emits a `<lib>.cddl` schema next to its `.h`/`.hpp`
and exposes a runtime discovery API (`<lib>_listApis`,
`<lib>_getSchema`) returning the same schema as a CBOR-encoded
`LibraryDescriptor`.

Build and run the CBOR-mode examples:

```sh
nimble runFfiCborExampleCpp     # build lib + jsoncons C++ example
nimble runFfiCborExamplePy      # build lib + generated Python wrapper + run
nimble runTypeMapTestLibCborPy  # full type-mapping parity test (Python)
nimble runTypeMapTestLibCborCpp # full type-mapping parity test (C++)
```

The C++ wrapper expects [jsoncons](https://github.com/danielaparker/jsoncons)
headers under `vendor/jsoncons/include` (header-only, no build step).
The Python wrapper requires `cbor2` on the active interpreter
(`pip install --user cbor2`).

| Aspect | Native strategy | CBOR strategy |
|--------|-----------------|---------------|
| C ABI surface | Per-request typed structs + free helpers | Fixed 10-function ABI + event callback typedef |
| Wire format | Native C structs (per-language conversion) | CBOR everywhere (`jsoncons` / `cbor2`) |
| Buffer ownership | Mixed (per-helper) | Uniform (Nim allocates, Nim frees) |
| Discovery API | Static headers | Static `<lib>.cddl` + runtime `_listApis` / `_getSchema` |
| Compile flag | `-d:BrokerFfiApiNative` (default) | `-d:BrokerFfiApiCBOR` |

### Torpedo Duel — a richer FFI API example

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
  delivered to Python.
- **Object-oriented state management** — all per-player state lives in a
  `Captain` ref object, created by `InitializeCaptainRequest` and torn down by
  `ShutdownRequest`. Only two threadvars remain per processing thread.
- **Callback lifetime safety** — the Python example shows the correct shutdown
  sequence: unregister all event listeners *before* the context manager calls
  `shutdown()`, preventing use-after-free on ctypes function pointers.
- **Deterministic replays** — identical seeds produce identical games, making
  the example useful for regression testing.

Build and run from the repository root:

```sh
nimble buildTorpedoExamplePy
nimble runTorpedoExamplePy          # default pacing
nimble runTorpedoExamplePy -- --fast # reduced delays
```

See [`examples/torpedo/DESIGN.md`](examples/torpedo/DESIGN.md) for the full
architecture, sequence diagrams, and API surface reference.

## BrokerContext

All three brokers support scoped instances via `BrokerContext`. This is useful when multiple independent components on the same thread each need their own broker state (e.g. separate listener/provider sets).

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

## Non-Object Types

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

```
Shared memory (process lifetime):
  Global bucket array    4 × sizeof(Bucket)          ~200 bytes (initial capacity 4)
  Lock (OS mutex)                                     ~40-64 bytes
  Init + count + cap                                  ~25 bytes

  Bucket[0]: (Default, threadA, chanA, signalA, threadGen, active, hasListeners)
  Bucket[1]: (Default, threadB, chanB, signalB, threadGen, active, hasListeners)
  Bucket[2]: (Default, threadC, chanC, signalC, threadGen, active, hasListeners)

  Channel[T] × 3         ~80 bytes each               ~240 bytes
    (one per listener-thread; mutex + condvar only — zero OS fds)

Per-thread (one-time, shared by ALL broker types on that thread):
  ThreadSignalPtr × 3    ~2 OS fds each (macOS: socketpair)
  brokerDispatchLoop: one Future per thread            ~128 bytes × 3

Threadvar (per thread, GC-managed):
  Thread A: tvCtxs[Default], tvHandlers[{1: cb1}], tvNextIds[2]
            ~16 + 48 + 8 = ~72 bytes
  Thread B: tvCtxs[Default], tvHandlers[{1: cb2, 2: cb3}], tvNextIds[3]
            ~16 + 96 + 8 = ~120 bytes
  Thread C: tvCtxs[Default], tvHandlers[{1: cb4}], tvNextIds[2]
            ~16 + 48 + 8 = ~72 bytes

Total: ~1.2 KB for 3 listener-threads, 4 listeners, 1 context.
```

**Key points:**
- Channels are allocated **per (BrokerContext, listener-thread)** pair — not per listener. Thread B's two listeners share one channel.
- Each `Channel[T]` uses only mutex + condvar — **zero OS file descriptors**.
- The `ThreadSignalPtr` (which holds the OS fd) is **shared** across all broker types on a thread. Adding more broker types costs zero additional fds.
- `brokerDispatchLoop`: a single shared async coroutine per thread wakes on the shared signal and drains all registered poll fns.
- Each bucket includes a `threadGen: uint64` field to disambiguate reused threadvar addresses across thread lifetimes, and an `active: bool` flag.
- Emitter threads allocate **zero** persistent memory — `emit()` only acquires the lock, snapshots targets, sends to each `Channel[T]`, and fires the target thread's shared signal.
- Buckets persist across `dropListener`/`listen` cycles (channel reuse).

### RequestBroker(mt) — example

**Scenario:** One `BrokerContext` (default). Thread A provides and also requests (same-thread). Threads B and C request cross-thread.

```
Shared memory (process lifetime):
  Global bucket array    4 × sizeof(Bucket)           ~160 bytes (initial capacity 4)
  Lock (OS mutex)                                      ~40-64 bytes
  Init + count + cap                                   ~25 bytes
  Timeout var (Duration = int64)                       ~8 bytes

  Bucket[0]: (Default, threadA, requestChan, providerSignal, threadGen)
    (RequestBroker has ONE bucket per context,
     unlike EventBroker which has one per listener-thread)

  Channel[T] × 1 (request channel)    ~80 bytes (mutex + condvar, zero OS fds)
    Shared by all requester threads

Per-thread (one-time, shared by ALL broker types on that thread):
  ThreadSignalPtr: providerSignal (thread A) + requesterSignal (each requester thread)
    Each = ~2 OS fds (macOS: socketpair)

Threadvar (provider thread A only):
  tvCtxs[Default], tvHandlers[handler]
  ~16 + 8 = ~24 bytes

Per-request (cross-thread only, transient):
  Response channel        ~80 bytes Channel[T] (createShared, no OS fds)
  One-shot poller registered on requester thread's dispatcher
  Deallocated on success; intentionally leaked on timeout (no OS resource leak)

Total baseline: ~400 bytes for 1 provider, 1 context.
```

**Per-request cost:**

| Path | Allocation | Lifetime |
|------|-----------|----------|
| Same-thread (Thread A → A) | Zero | — |
| Cross-thread (Thread B → A) | ~80 bytes response channel | Freed after response; leaked on timeout (safe — no OS fds) |

**Key points:**
- Same-thread requests have **zero channel overhead** — the provider handler is called directly from threadvar.
- Cross-thread requests allocate one `Channel[T]` for the response per call (~80 bytes, zero OS fds). Deallocated on success. On timeout, leaked safely (provider's eventual `send` writes into an unread channel — no crash, no OS resource leak).
- The request channel is shared — all requester threads `send` into the same `Channel[T]`. A shared `brokerDispatchLoop` on the provider thread drains it via `tryRecv`.
- Adding a second `BrokerContext` on the same provider thread costs one additional bucket + channel (~160 bytes) plus one threadvar entry (~24 bytes).

### Comparison

| | EventBroker | RequestBroker | EventBroker(mt) | RequestBroker(mt) |
|---|---|---|---|---|
| Storage | threadvar only | threadvar only | createShared + threadvars | createShared + threadvars |
| Shared memory | None | None | Bucket array + Lock | Bucket array + Lock |
| Channels | None | None | One `Channel[T]` per listener-thread | One `Channel[T]` per context (request) + one per cross-thread call (response) |
| Per-call cost | Zero | Zero | Zero | ~80 bytes response channel (cross-thread only) |
| OS resources | None | None | **One** `ThreadSignalPtr` per thread (shared by all broker types) | **One** `ThreadSignalPtr` per thread (shared) |
| Baseline per context | ~100 bytes | ~16 bytes | ~300 bytes (bucket + Channel[T] + poll fn) | ~300 bytes (bucket + Channel[T] + poll fn) |
| Intentional leaks | None | None | Channel[T] on shutdown (no OS fds — safe) | Response Channel[T] on timeout (no OS fds — safe) |

## Platform & Nim Version Support

Single-thread brokers run on every supported platform under both `--mm:orc`
and `--mm:refc`. Multi-thread (`(mt)`) brokers and the Broker FFI API have
narrow, documented carve-outs — refc on Windows is unsupported, refc on
macOS + Nim 2.2.4 + debug skips a defined set of stress tests, and Nim
versions older than 2.2.0 are unsupported.

Recommended baseline: **Nim ≥ 2.2.10 with `--mm:orc`**. ORC has no known
limitations on any supported platform.

See [LIMITATION.md](LIMITATION.md) for the full support matrix, the
per-platform issue analysis (Windows refc + chronos thread-pool callback,
macOS + 2.2.4 stdlib `Channel[T].send` regression, devel allocator
regression, etc.), and the compile-time test-exclusion mechanism used to
keep CI green on the known-fragile combos.

### Windows toolchain requirements

The Broker FFI API requires LLVM clang and Ninja on `PATH` for FFI builds
on Windows (the bundled MinGW `gcc` mismatches the cmake-side MSVC CRT and
produces cross-heap crashes). When running the AddressSanitizer tasks,
`clang_rt.asan_dynamic-x86_64.dll` from
`C:\Program Files\LLVM\lib\clang\<ver>\lib\windows\` must also be on
`PATH`; the `memcheck_ci.yml` workflow handles this for CI. See
LIMITATION.md → §2.1 for the toolchain rationale.

## Testing

```
nimble test
```

## Debug

To inspect generated AST during compilation:

```
nim c -d:brokerDebug ...
```

## License

MIT
