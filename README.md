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

## Platform Support

The single-thread brokers (`EventBroker`, `RequestBroker`, `MultiRequestBroker`)
are pure threadvar code with no chronos cross-thread machinery — every memory
manager works on every platform. The multi-thread (`(mt)`) brokers and the
Broker FFI API both use chronos' `ThreadSignalPtr` for cross-thread wakeup; on
Windows that primitive routes through `RegisterWaitForSingleObject`, which
fires its completion callback on a Win32 thread-pool thread the refc GC
cannot suspend (see [Known Limitations](#known-limitations) for the full
reasoning). As a result, **`--mm:refc` is unsupported on Windows for the
multi-thread brokers and the Broker FFI API** — use `--mm:orc` (Nim's default
since 2.0).

| Layer | Linux orc | Linux refc | macOS orc | macOS refc | Windows orc | Windows refc |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| `EventBroker` (single-thread) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `RequestBroker` (single-thread) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `MultiRequestBroker` (single-thread) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `EventBroker(mt)` | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| `RequestBroker(mt)` | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| `EventBroker(API)` (Broker FFI) | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| `RequestBroker(API)` (Broker FFI) | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| `registerBrokerLibrary` (FFI runtime) | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |

The `nimble` test tasks reflect this matrix: refc combinations for `(mt)` and
`(API)` brokers are **automatically skipped on Windows** with a clear log
message. CI does not enforce them, and consuming projects should build
Windows binaries with `--mm:orc`.

## Supported Nim Versions

| Nim version | CI status | Notes |
|---|---|---|
| **2.2.x** (current head of `version-2-2` branch — 2.2.10 at time of writing) | ✅ blocking | Recommended. The minimum supported stable release. |
| **devel** (currently 2.3.x) | ⚠️ manual | Not part of the blocking PR matrix. GitHub Actions does not allow `continue-on-error` on reusable-workflow callers, and `nimbus-common-workflow` exposes no informational-version flag. Devel coverage is on-demand via the **`memcheck_ci.yml` → "Run workflow" → `nim-version: devel`** dispatch (or by running the same `nimble` tasks locally). The current 2.3.x regression is documented under [Known Limitations](#known-limitations). |
| **2.0.x** and earlier | ❌ unsupported | Dropped on 2026-05-04. Refc + foreign-thread allocator on macOS deterministically SIGSEGVs in `genericSeqAssign`/`rawAlloc` for `seq[object]` and `array[N,T]` payloads crossing the FFI boundary. 2.2 fixes that path. |

If you build an FFI API library on top of nim-brokers, pin `requires "nim >= 2.2.0"` in your `.nimble` file. Single-thread brokers compile fine on older Nim too, but the multi-thread and FFI paths assume 2.2's runtime fixes.

## Windows Support

The Broker FFI API is supported on Windows, but with stricter toolchain
requirements than Linux/macOS. The reason is the Windows C runtime split: a
Nim-built DLL and a C/C++/Python consumer **must share the same C runtime**,
otherwise pointers allocated on one heap and freed on the other (or
unmatched stdio/TLS/exception state) produce intermittent crashes — typically
at process teardown, occasionally earlier.

### Required toolchain on Windows

- **LLVM 19+ (clang, clang++, lld, llvm-symbolizer) on `PATH`.** The
  `nimble` tasks for FFI builds force `--cc:clang` on Windows so the Nim
  DLL links against the release UCRT (`ucrtbase.dll`, `MSVCP140.dll`).
  The default Nim toolchain shipped by `setup-nim-action` is MinGW gcc
  (`msvcrt.dll`), which is **not compatible** with MSVC- or clang-built
  consumers across a DLL boundary.
- **Ninja on `PATH`.** All `nimble` cmake tasks switch to
  `-G Ninja -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ -DCMAKE_LINKER_TYPE=LLD`
  on Windows. The default Visual Studio + MSVC generator silently ignores
  the requested compiler for the toolset, links the C++ side against the
  debug UCRT (`ucrtbased.dll`) for Debug configurations, and link.exe
  cannot consume clang's `-fsanitize=address` output.
- **Release UCRT pinning.** All Windows cmake configurations are driven
  with `-DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL`
  so consumer binaries match the release UCRT used by the Nim DLL.
- **AddressSanitizer.** When running the `*Asan*` tasks on Windows
  (`testFfiApiCppAsan*`, `testMt*Asan*`), the workflow additionally
  prepends the directory of `clang_rt.asan_dynamic-x86_64.dll`
  (typically under `C:\Program Files\LLVM\lib\clang\<ver>\lib\windows\`)
  to `PATH`. Without it the test executable fails `STATUS_DLL_NOT_FOUND`
  on launch with no diagnostic output.

### Limitations on Windows

- **`--mm:refc` is unsupported for FFI API tests.** See the dedicated
  note under [Known Limitations](#known-limitations) — a Windows
  thread-pool callback used by chronos' async wait is invisible to the
  refc stop-the-world GC. Use `--mm:orc` (the default since Nim 2.0).
- **`--nimMainPrefix` is unused on Windows.** See [Known
  Limitations](#known-limitations) for the rationale.
- **CRT-mixing with MinGW-built consumers is not supported.** The Nim
  DLLs produced by these tasks expect MSVC-compatible consumers built
  with clang or clang-cl on the release UCRT. Pure-MinGW consumer
  builds are out of scope.
- **C/C++/Python consumers must use a single CRT.** When linking against
  the generated `<libname>.lib` import library, build with the same
  release UCRT (`/MD`) settings used here. Mixing `/MDd` with the
  Nim-built DLL produces the cross-heap bad-free symptom.

### Verifying on Windows locally

From a shell with LLVM and Ninja on `PATH`:

```
nimble testApi
nimble testFfiApi
nimble testFfiApiCpp
nimble runFfiExampleC
nimble runFfiExampleCpp
nimble runFfiExamplePy
```

The `Memcheck CI` GitHub Actions workflow (`memcheck_ci.yml`) covers the
same tasks plus the AddressSanitizer variants.

## Known Limitations

### `--mm:refc` is unsupported on Windows for the multi-thread and FFI API brokers

`nimble test`, `nimble perftest`, `nimble testApi`, `nimble testFfiApi`,
`nimble testFfiApiCpp`, `testFfiApiCppAsanRefc`, `testMtEventBrokerAsanRefc`
and `testMtRequestBrokerAsanRefc` automatically skip `--mm:refc` variants on
Windows. ORC (`--mm:orc`) is fully supported on every platform and is the
recommended memory manager for nim-brokers code that crosses thread
boundaries on Windows.

**Root cause.** Both the `(mt)` brokers and the Broker FFI API runtime use
chronos' `ThreadSignalPtr.wait()` to receive cross-thread wakeups. On Windows
the chronos implementation registers a completion callback through the
Win32 `RegisterWaitForSingleObject` API, and the OS fires that callback on a
**Windows thread-pool thread** — a thread that is not a Nim thread and is
therefore invisible to the garbage collector.

Refc's garbage collector is stop-the-world: it pauses every *known* Nim
thread before scanning the heap. Because the thread-pool thread is unknown,
refc can free futures and wait-handles that the callback is still
referencing, producing access violations and use-after-free bugs. ORC has no
stop-the-world phase — its reference counting is fully atomic and its cycle
collector runs in-thread — so the same thread-pool callback is safe.

**Why `(mt)` brokers are also affected on Windows.** Earlier documentation
said `(mt)` refc tests pass on Windows because their workloads tend to keep
the broker signal pre-fired by the time the dispatcher polls, sometimes
short-circuiting the `RegisterWaitForSingleObject` slow path. That is true
for the existing test suite under light load, but it is a property of the
test patterns — not a guarantee. Sustained idle periods, foreign-thread
attaches, and stress workloads such as ASAN's
`test_foreign_thread_concurrent_lifecycle` all reach the slow path and
expose the same use-after-free deterministically. Treat `(mt)` refc on
Windows the same as FFI API refc: unsupported.

**Why the FFI API cannot work around it.** The FFI API runtime spawns
dedicated processing and delivery threads that block on
`ThreadSignalPtr.wait()` by design, and foreign threads (C / C++ / Python)
drive that wait through requests, event registrations and lifecycle
operations. The thread-pool callback path is therefore part of the steady
state, not a corner case. A workaround would require either an upstream
chronos rewrite of the Windows wait primitive, or replacing
`ThreadSignalPtr` in `mt_broker_common.nim` with a Nim-thread-only
blocking-receive design — both substantial efforts that would still leave
foreign-thread attach/detach hazards for refc unresolved. Given that ORC is
Nim's default since 2.0 and refc is legacy, neither workaround is
worthwhile.

**Recommendation.** Build any nim-brokers code that uses `(mt)` brokers or
the Broker FFI API on Windows with `--mm:orc`. Single-thread brokers remain
fully refc-compatible on every platform.

### Nim devel (2.3.x) refc release-mode FFI crash

Tracked, not blocking. CI runs Nim devel as `continue-on-error: true` (`build-devel` job in `ci.yml`). Locally reproducible on macOS arm64 with `--mm:refc -d:release` and Nim 2.3.1: after roughly four `createContext` / `shutdown` lifecycle iterations, the next allocation crashes inside the refc allocator at `system/alloc.nim:942` (`c.freeList = c.freeList.next` reading address `0x8`). The same code passes on Nim 2.0.16, 2.2.10 and on devel under refc *debug*; only refc + release + devel crashes.

The crash signature is heap corruption — `c.freeList` is non-nil at line 939 but stale by line 942 — consistent with a release-mode codegen / GC regression on the cross-thread allocator path that ships in 2.3.x. Workarounds inside nim-brokers would be brittle; the right fix is upstream. We refresh devel coverage on every CI run so that once the regression clears, the informational job will go green again.

If you hit this locally, switch to `--mm:orc` or pin to Nim 2.2.x stable.

### `--nimMainPrefix` is not needed on Windows, and cannot be used there

`--nimMainPrefix` exists to avoid `NimMain` symbol collisions when multiple Nim `.so` files are loaded in the same POSIX process. On Linux/macOS, `dlopen` with `RTLD_GLOBAL` merges all shared-object exports into a single flat namespace, so two Nim libraries that both define `NimMain` clash. The prefix renames them (e.g. `fooNimMain`, `barNimMain`) to prevent that.

On Windows the PE loader works differently: every import is resolved as `DLL!Symbol`, so `foo.dll!NimMain` and `bar.dll!NimMain` are entirely separate entries that never interfere with each other. Any number of Nim DLLs can be loaded into the same process without a prefix.

Attempting to use `--nimMainPrefix` on Windows also triggers a Nim codegen bug: the C generator forward-declares the prefixed `NimMain` without `__declspec(dllexport)` and then defines it with `N_LIB_EXPORT`, which both clang and GCC reject as a hard error (`err_attribute_dll_redeclaration`).

The `nimble testFfiApi` task therefore omits `--nimMainPrefix` on Windows, which is the correct behaviour — not a workaround.

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
