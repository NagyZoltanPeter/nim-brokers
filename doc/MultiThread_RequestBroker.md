# Multi-Thread RequestBroker

## Overview

`RequestBroker(mt):` generates a **multi-thread capable** request/response broker.
The provider runs on the thread that called `setProvider` and serves requests from
any thread in the process. Same-thread requests bypass channels entirely and call the
provider directly.

The broker **does not own or spawn threads**. Thread management is your responsibility.

```nim
import request_broker

RequestBroker(mt):
  type Weather = object
    city*: string
    tempC*: float
    humidity*: int

  proc signature*(city: string): Future[Result[Weather, string]] {.async.}
```

This generates:

| Proc | Description |
|------|-------------|
| `Weather.setProvider(handler)` | Register a provider on the current thread (default context) |
| `Weather.setProvider(ctx, handler)` | Register a provider on the current thread (keyed context) |
| `Weather.request(city)` | Issue a request (default context) |
| `Weather.request(ctx, city)` | Issue a request (keyed context) |
| `Weather.clearProvider()` | Unregister provider + shut down process loop (default context) |
| `Weather.clearProvider(ctx)` | Unregister provider + shut down process loop (keyed context) |
| `Weather.setRequestTimeout(duration)` | Set cross-thread request timeout (default: 5 seconds) |
| `Weather.requestTimeout()` | Get current cross-thread request timeout |

---

## Quick Start

### Single provider, cross-thread request

```nim
import std/atomics
import chronos
import request_broker

RequestBroker(mt):
  type Greeting = object
    message*: string

  proc signature*(name: string): Future[Result[Greeting, string]] {.async.}

# ── Provider thread (main) ─────────────────────────────

proc main() {.async.} =
  check Greeting.setProvider(
    proc(name: string): Future[Result[Greeting, string]] {.async.} =
      ok(Greeting(message: "Hello, " & name & "!"))
  ).isOk()

  # Spawn a worker thread that issues a request.
  var done: Atomic[bool]
  done.store(false)

  proc worker() {.thread.} =
    let res = waitFor Greeting.request("Alice")
    assert res.isOk()
    echo res.value.message       # "Hello, Alice!"
    done.store(true)

  var t: Thread[void]
  t.createThread(worker)

  # Keep event loop alive so the process loop can serve the request.
  while not done.load():
    await sleepAsync(10.milliseconds)

  t.joinThread()
  Greeting.clearProvider()

waitFor main()
```

### Multiple isolated contexts

```nim
let ctxEN = NewBrokerContext()
let ctxDE = NewBrokerContext()

check Greeting.setProvider(ctxEN,
  proc(name: string): Future[Result[Greeting, string]] {.async.} =
    ok(Greeting(message: "Hello, " & name & "!"))
).isOk()

check Greeting.setProvider(ctxDE,
  proc(name: string): Future[Result[Greeting, string]] {.async.} =
    ok(Greeting(message: "Hallo, " & name & "!"))
).isOk()

let en = await Greeting.request(ctxEN, "Bob")  # "Hello, Bob!"
let de = await Greeting.request(ctxDE, "Bob")  # "Hallo, Bob!"
```

---

## Important Notices

### 1. The provider thread must keep its chronos event loop running

`setProvider` uses `asyncSpawn` to start the internal process loop on the
**current thread's chronos event loop**. If the event loop stops (e.g.
`waitFor` returns), the process loop can no longer receive cross-thread
requests.

When writing tests or applications, keep the event loop alive:

```nim
# GOOD: async loop stays alive while worker threads run.
proc main() {.async.} =
  check MyType.setProvider(handler).isOk()
  var t: Thread[void]
  t.createThread(worker)
  while not done.load():
    await sleepAsync(10.milliseconds)
  t.joinThread()
  MyType.clearProvider()
waitFor main()

# BAD: waitFor blocks the event loop — cross-thread requests will hang.
proc main() =
  check MyType.setProvider(handler).isOk()
  var t: Thread[void]
  t.createThread(worker)
  t.joinThread()             # Blocks! Process loop is starved.
  MyType.clearProvider()
```

### 2. Thread procs cannot be closures — but provider handlers can

Nim's `{.thread.}` pragma requires `nimcall` convention (no captured
variables). This applies to procs passed to `createThread`, i.e. your
**worker/requester thread procs**. Use module-level procs with global
`Atomic` variables for synchronization:

```nim
var gDone: Atomic[bool]

proc worker() {.thread.} =
  let res = waitFor MyType.request("data")
  doAssert res.isOk()
  gDone.store(true)
```

**Provider handlers** are not affected by this restriction. The handler
closure passed to `setProvider` is stored in a `threadvar` on the provider
thread and called locally by `processLoop` — it never crosses a thread
boundary. Capturing variables from the provider thread's scope is safe:

```nim
proc main() {.async.} =
  var requestCount = 0

  check MyType.setProvider(
    proc(input: string): Future[Result[MyType, string]] {.async.} =
      requestCount += 1          # ✅ captured — runs on provider thread
      ok(MyType(value: input))
  ).isOk()
```

### 3. One provider per BrokerContext, one thread owns it

Each `BrokerContext` can only have one provider, and it is bound to the
thread that called `setProvider`. A second thread calling `setProvider` for
the same context will get an error:

```
RequestBroker(MyType): provider already set from another thread
```

Multiple contexts **can** coexist on the same thread or across different threads.

### 4. Use `waitFor` in non-async thread procs

Inside `{.thread.}` procs (which are synchronous), use `waitFor` to block
until the request completes:

```nim
proc worker() {.thread.} =
  let res = waitFor MyType.request("hello")
```

The `blockingAwait` template is also available as an alias for `waitFor`:

```nim
import mt_request_broker  # exports blockingAwait
let res = blockingAwait MyType.request("hello")
```

Do **not** use chronos's `await` outside of `{.async.}` procs.

### 5. `clearProvider` must be called from the provider thread

`clearProvider` cleans threadvar entries, which are only accessible from the
thread that created them. Always call `clearProvider` from the same thread
that called `setProvider`.

### 6. ORC and refc compatibility

The broker works with both `--mm:orc` and `--mm:refc`. The global registry
uses `createShared` / `deallocShared` for raw memory (no GC involvement).
Provider closures live in threadvars (GC-managed, per-thread), avoiding
cross-thread GC issues entirely.

Under `--mm:refc`, threadvar addresses (`currentMtThreadId()`) can be reused
when threads exit and new ones are created. Each bucket stores a `threadGen`
(monotonically increasing counter from `currentMtThreadGen()`) alongside the
`threadId` to disambiguate thread incarnations. All identity checks match on
both `threadId` and `threadGen`.

**`clearProvider` on a dead provider thread:** If the provider thread exits
without calling `clearProvider`, a cross-thread `clearProvider` call sends a
shutdown message into the orphaned request channel. Because `AsyncChannel` is
unbounded, `sendSync` returns immediately — the message sits unread. This is a
small harmless leak (~200 bytes + signal handle), not a hang.

### 7. Cross-thread request timeout

Cross-thread requests have a configurable timeout (default: **5 seconds**). If the
provider thread does not respond within the timeout, `request()` returns an error
result instead of hanging indefinitely. This protects against blocked or
unresponsive provider threads.

```nim
# Check current timeout
echo Weather.requestTimeout()          # 5 seconds (default)

# Set a shorter timeout
Weather.setRequestTimeout(chronos.seconds(2))

# Cross-thread requests now time out after 2 seconds
let res = waitFor Weather.request("Berlin")
if res.isErr() and "timed out" in res.error():
  echo "Provider did not respond in time"
```

**Important notes:**

- The timeout applies **only to cross-thread requests**. Same-thread requests call
  the provider directly and are not affected by the timeout setting.
- The timeout variable is per-type, module-level — it is shared across all threads
  and all `BrokerContext` instances for that broker type.
- When a timeout occurs, the one-shot response channel is **left open and not
  deallocated** — this is an intentional leak. `AsyncChannel.close()` destroys the
  inner `Channel` (calls `deallocShared` on it and nils the pointer), so a later
  provider `sendSync` would dereference nil and crash. By leaving the channel open,
  the provider's eventual `sendSync` succeeds harmlessly — it writes into a channel
  nobody reads. The leak is ~200 bytes + one OS signal handle per timed-out request.
  A future upstream fix in `nim-asyncchannels` (e.g. a `trySendSync` that returns
  bool on closed channel, or a `close` that defers inner dealloc) would allow safe
  cleanup. The same intentional-leak strategy is used for request channels at
  teardown.

### 8. Compile with `--threads:on`

Multi-thread mode requires the Nim compiler flag `--threads:on`.

---

## Call Sequence Diagrams

### Cross-Thread Request (the common case)

```mermaid
sequenceDiagram
    box Provider Thread (owns event loop)
        participant PT as Provider Thread
        participant PL as processLoop
        participant H as handler(args)
    end
    box Requester Thread ({.thread.} proc)
        participant RT as Requester Thread
    end
    participant RC as requestChan<br/>(AsyncChannel)
    participant RSP as responseChan<br/>(one-shot)

    Note over PT: setProvider(handler) already called.<br/>processLoop is asyncSpawn'ed<br/>on the provider's event loop.

    PL ->> RC: await recv()
    activate PL
    Note right of PL: NON-BLOCKING<br/>yields to event loop

    RT ->> RT: Lock → find bucket → Unlock
    RT ->> RSP: createShared + open()
    activate RSP
    Note right of RSP: ad-hoc response channel

    RT ->> RC: sendSync(requestMsg)
    activate RT
    Note left of RT: BLOCKS briefly<br/>(channel has room)
    RC -->> PL: msg received
    deactivate PL
    deactivate RT

    PL ->> PL: look up handler from threadvar
    PL ->> H: await handler(args)
    activate H
    Note over H: NON-BLOCKING<br/>runs on provider's<br/>event loop

    RT ->> RSP: waitFor withTimeout(recv(), timeout)
    activate RT
    Note left of RT: BLOCKS<br/>spins chronos event loop<br/>until response or timeout (default 5s)

    H -->> PL: Result[T, string]
    deactivate H

    PL ->> RSP: sendSync(result)
    Note right of PL: BLOCKS briefly

    RSP -->> RT: result received
    deactivate RT
    RT ->> RSP: close() + deallocShared (success path only)
    deactivate RSP

    RT ->> RT: return Result[T, string]

    PL ->> RC: await recv() (loop)
    Note right of PL: back to waiting
```

**Blocking points summary:**

| Operation | Thread | Blocking? | Duration |
|-----------|--------|-----------|----------|
| `sendSync(requestMsg)` | Requester | **Blocks** | Near-instant (channel has capacity) |
| `waitFor recv(responseChan)` | Requester | **Blocks** | Until provider responds or timeout (default 5s) |
| `await recv(requestChan)` | Provider | Non-blocking | Yields to event loop |
| `await handler(...)` | Provider | Non-blocking | Yields to event loop |
| `sendSync(result)` | Provider | **Blocks** | Near-instant (channel has capacity) |


### Same-Thread Request (fast path)

```mermaid
sequenceDiagram
    participant T as Same Thread<br/>(provider + requester)
    participant TV as threadvar seqs
    participant H as handler(args)

    T ->> T: request("hello")
    T ->> T: Lock → find bucket →<br/>threadId+threadGen match → sameThread=true → Unlock
    T ->> TV: scan for brokerCtx
    TV -->> T: handler found

    T ->> H: await handler("hello")
    activate H
    Note over H: Direct call — NO channels<br/>Runs on same event loop<br/>NON-BLOCKING (async)
    H -->> T: Result[T, string]
    deactivate H

    T ->> T: return Result[T, string]

    Note over T: Zero channel allocations.<br/>Zero sendSync.<br/>Zero additional threads.
```


### setProvider Flow (detailed)

```mermaid
sequenceDiagram
    participant CT as Calling Thread
    participant TV as threadvar seqs
    participant GL as globalLock
    participant B as Shared Buckets
    participant CH as AsyncChannel<br/>(new)
    participant EL as Event Loop

    CT ->> CT: ensureInit()
    Note right of CT: first call: initLock,<br/>createShared bucket array

    CT ->> TV: scan for duplicate brokerCtx
    alt already registered
        TV -->> CT: found
        CT ->> CT: return err("already set")
    end

    CT ->> TV: append (brokerCtx, handler)
    Note right of TV: GC-managed, per-thread

    CT ->> GL: withLock(globalLock)
    activate GL

    CT ->> B: scan buckets for brokerCtx
    alt found, same threadId+threadGen
        B -->> CT: match (same thread incarnation)
        CT ->> GL: unlock
        CT ->> CT: return ok()
        Note right of CT: other signature registered first
    else found, different threadId or threadGen
        B -->> CT: match (OTHER thread!)
        CT ->> TV: undo append (setLen - 1)
        CT ->> GL: unlock
        CT ->> CT: return err("already set from another thread")
    else not found
        CT ->> CH: createShared(AsyncChannel)
        activate CH
        CT ->> CH: open()
        CT ->> B: store bucket {brokerCtx, chan, threadId, threadGen}
        CT ->> B: bucketCount += 1
        CT ->> EL: asyncSpawn processLoop(chan, brokerCtx)
        Note over EL: process loop begins on<br/>THIS thread's event loop
        CT ->> GL: unlock
        CT ->> CT: return ok()
    end
    deactivate GL
    deactivate CH
```


### clearProvider Flow

```mermaid
sequenceDiagram
    participant PT as Provider Thread
    participant TV as threadvar seqs
    participant GL as globalLock
    participant B as Shared Buckets
    participant PL as processLoop

    PT ->> TV: scan + remove matching brokerCtx entry
    Note right of TV: safe: called from<br/>provider thread

    PT ->> GL: withLock(globalLock)
    activate GL
    PT ->> B: find bucket by brokerCtx
    B -->> PT: requestChan pointer saved
    PT ->> B: remove bucket (shift array)
    PT ->> B: bucketCount -= 1
    PT ->> GL: unlock
    deactivate GL

    PT ->> PL: sendSync(shutdownMsg) via requestChan
    Note right of PT: BLOCKS briefly

    PL ->> PL: recv() returns shutdownMsg
    PL ->> PL: break out of while loop
    PL ->> PL: async proc completes

    Note over PT: done
```


### Multi-Context, Multi-Thread Overview

```mermaid
sequenceDiagram
    box 
        participant TA as Thread A (main)
    end
    box 
        participant TB as Thread B (worker)
    end
    box 
        participant TC as Thread C (requester)
    end
    participant REG as Shared Registry<br/>(Lock-protected)

    TA ->> REG: setProvider(ctxA, handlerA)
    Note over TA,REG: Thread A owns ctxA

    TB ->> REG: setProvider(ctxB, handlerB)
    Note over TB,REG: Thread B owns ctxB

    TC ->> REG: request(ctxA, "hello")
    REG -->> TC: routed to Thread A's requestChan
    Note right of TC: cross-thread → channel I/O

    TA -->> TC: Result from handlerA

    TC ->> REG: request(ctxB, "world")
    REG -->> TC: routed to Thread B's requestChan
    Note right of TC: cross-thread → channel I/O

    TB -->> TC: Result from handlerB

    TA ->> REG: request(ctxA, "local")
    Note over TA: same-thread → direct call<br/>(no channels)
    TA ->> TA: handlerA("local") → Result
```

---

## Memory Layout

```
                 SHARED MEMORY (createShared)              THREAD-LOCAL (threadvar)
                ┌───────────────────────────────┐           ┌──────────────────────────┐
                │  gBuckets: ptr UncheckedArray │           │ Thread A:                │
                │  ┌─────────────────────────┐  │           │  tvCtxs:     [ctx0,ctx1] │
                │  │ [0] brokerCtx: ctx0     │  │           │  tvHandlers: [h0,  h1  ] │
                │  │     requestChan: ──────►│──│──►chan0   │                          │
                │  │     threadId: addrA     │  │           ├──────────────────────────┤
                │  │     threadGen: 0        │  │           │ Thread B:                │
                │  ├─────────────────────────┤  │           │  tvCtxs:     [ctx2]      │
                │  │ [1] brokerCtx: ctx1     │  │           │  tvHandlers: [h2  ]      │
                │  │     requestChan: ──────►│──│──►chan0   │                          │
                │  │     threadId: addrA     │  │  (shared) └──────────────────────────┘
                │  │     threadGen: 0        │  │
                │  ├─────────────────────────┤  │
                │  │ [2] brokerCtx: ctx2     │  │
                │  │     requestChan: ──────►│──│──►chan2
                │  │     threadId: addrB     │  │
                │  │     threadGen: 1        │  │
                │  └─────────────────────────┘  │
                │  gBucketCount: 3              │
                │  gBucketCap: 4                │
                │  gLock: Lock                  │
                └───────────────────────────────┘

Note: ctx0 and ctx1 are on the same thread (Thread A), so they share the
same requestChan. Each context has its own handler in the threadvar seqs.
```

---

## Performance and Memory Footprint Analysis

### Per-Broker Overhead (one-time, at `setProvider`)

| Component | Size | Lifetime |
|-----------|------|----------|
| Global bucket array | `4 * sizeof(MtBucket)` initially (~128 bytes), doubles on growth | Process lifetime |
| `Lock` (OS mutex) | ~40-64 bytes (platform-dependent) | Process lifetime |
| Init + count + cap vars | 3 `int` + 1 `bool` = ~25 bytes | Process lifetime |
| `AsyncChannel[RequestMsg]` per context | ~200 bytes (`createShared`) | Intentionally leaked (see below) |
| Threadvar seqs (per provider thread) | 2 `seq` headers (~32 bytes) + entries | Thread lifetime |
| Process loop coroutine | One `Future` on the event loop (~128 bytes) | Until `clearProvider` |

**Total per-context registration: ~400-500 bytes.**

Contexts on the same thread share a single `requestChan` and process loop,
so the marginal cost of a second context on the same thread is only the
threadvar seq entry (~16 bytes for ctx + pointer).

### Per-Request Overhead

#### Same-thread request (fast path)

| Operation | Cost |
|-----------|------|
| Lock acquire + bucket scan + unlock | ~50-200 ns (uncontended mutex + linear scan over <=N buckets) |
| Threadvar seq scan | ~10-50 ns (linear scan, typically 1-3 entries) |
| Provider call | Direct `await handler(args)` — zero allocation overhead |

**Total: equivalent to a virtual function call + mutex.**

No channel allocations. No data copying beyond normal parameter passing.

#### Cross-thread request

| Operation | Cost |
|-----------|------|
| Lock acquire + bucket scan + unlock | ~50-200 ns |
| `createShared(AsyncChannel[Result])` | ~200 bytes allocation (OS allocator, not GC) |
| `open(responseChan)` | Channel initialization |
| `sendSync(requestMsg)` to requestChan | Copies the `RequestMsg` struct into channel buffer. **Blocks briefly** (channel has capacity 1, provider drains it). Under `--mm:refc`, string fields are deep-copied. |
| `await responseChan.recv()` on requester | Requester blocks (via `waitFor` spinning a temporary event loop) |
| `sendSync(result)` from provider | Copies the `Result[T, string]` into response channel. Under `--mm:refc`, result type fields are deep-copied. |
| `close(responseChan)` + `deallocShared` | Channel teardown + OS dealloc (success path; on timeout the channel is intentionally leaked open) |

**Total: ~2-5 us per cross-thread request** (dominated by channel alloc/dealloc and
context switches).

### Deep-Copy Cost under `--mm:refc`

Under `refc`, `sendSync` performs a **deep copy** of the message. If your
request type contains large strings, sequences, or ref objects, each
cross-thread request copies that data twice (request message + response
message).

Under `--mm:orc`, move semantics reduce this to near-zero for most cases.

**Recommendation:** For large payloads, prefer `--mm:orc`. For small value
types (ints, short strings, fixed-size objects), both memory managers
perform similarly.

### Lock Contention

The global `Lock` is held **only** during:
- `setProvider` (bucket registration) — once per provider setup
- `request` (bucket lookup) — brief read-only scan per request
- `clearProvider` (bucket removal) — once per cleanup

The lock is **not** held during handler execution or channel I/O. Under
typical usage (1-4 contexts, rare provider changes), contention is
negligible. The lock acquisition is the standard OS mutex fast path
(~20-50 ns uncontended).

### Channel Allocation Strategy

Each cross-thread request allocates a one-shot `AsyncChannel` for the
response. This is a deliberate tradeoff:

- **Pro:** Simple, no response routing needed, no shared response queue
- **Pro:** No risk of response mismatch between concurrent requesters
- **Con:** `createShared` + `deallocShared` per request (~200 bytes)

For high-throughput scenarios (>10,000 requests/sec), we may consider pooling
response channels or batching requests at the application level.
This is certainly an optimization point, as we can expect requests from one thread to be sequential for RequestBroker- and broker-context-wise, so we can reuse the same channel for multiple requests.

### Scaling Characteristics

| Dimension | Scaling |
|-----------|---------|
| Number of contexts | Linear bucket scan under lock. Practical limit: ~100 contexts (scan is ~microseconds) |
| Number of concurrent requesters | Each gets its own response channel. Provider serves sequentially via event loop. Throughput limited by handler execution time. |
| Number of provider threads | Each owns independent contexts. No cross-provider contention. |
| Message size | Linear with `sendSync` copy cost. Affects refc more than ORC. |

### Comparison with Single-Thread RequestBroker

| Aspect | `RequestBroker():` (single-thread) | `RequestBroker(mt):` (multi-thread) |
|--------|------------------------------------|-------------------------------------|
| Provider storage | `{.threadvar.}` | `{.threadvar.}` + shared bucket registry |
| Request dispatch | Direct proc call | Same-thread: direct. Cross-thread: channel I/O |
| Lock overhead | None | One mutex acquire/release per request |
| Memory per request | Zero | Cross-thread: ~200 bytes (response channel) |
| Thread safety | None (same thread only) | Full cross-thread support |
| Latency (same thread) | ~10 ns | ~50-200 ns (lock overhead) |
| Latency (cross thread) | N/A | ~2-5 us |

---

## Compilation

```sh
# ORC (recommended)
nim c -r --mm:orc --threads:on --path:src test/test_multi_thread_request_broker.nim

# refc (compatible)
nim c -r --mm:refc --threads:on --path:src test/test_multi_thread_request_broker.nim
```

Or via nimble:

```sh
nimble test
```
