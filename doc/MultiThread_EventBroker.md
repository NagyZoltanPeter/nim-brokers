# Multi-Thread EventBroker

## Overview

`EventBroker(mt):` generates a **multi-thread capable** pub/sub event broker.
Listeners can be registered on **any** thread; events emitted from **any** thread
are broadcast to all registered listeners (fire-and-forget). Same-thread delivery
bypasses channels entirely and dispatches directly via `asyncSpawn`.

The broker **does not own or spawn threads**. Thread management is your responsibility.

```nim
import brokers/event_broker

EventBroker(mt):
  type Alert = object
    level*: int
    message*: string
```

This generates:

| Proc | Description |
|------|-------------|
| `Alert.listen(handler)` | Register a listener on the current thread (default context) |
| `Alert.listen(ctx, handler)` | Register a listener on the current thread (keyed context) |
| `Alert.emit(event)` | Broadcast an event to all listeners (default context) |
| `Alert.emit(ctx, event)` | Broadcast an event to all listeners (keyed context) |
| `Alert.emit(level=1, message="hi")` | Field-constructor emit (inline object types only) |
| `await Alert.dropListener(handle)` | Remove a listener and drain in-flight futures (must be on registering thread, 5 s timeout) |
| `Alert.dropAllListeners()` | Remove all listeners for default context, drain in-flight (any thread) |
| `Alert.dropAllListeners(ctx)` | Remove all listeners for keyed context, drain in-flight (any thread) |

---

## Quick Start

### Cross-thread emit to main-thread listener

```nim
import std/atomics
import chronos
import brokers/event_broker

EventBroker(mt):
  type ChatMsg = object
    user*: string
    text*: string

proc main() {.async.} =
  var received: Atomic[int]
  received.store(0)

  discard ChatMsg.listen(
    proc(evt: ChatMsg): Future[void] {.async: (raises: []).} =
      echo evt.user, ": ", evt.text
      discard received.fetchAdd(1)
  )

  proc worker() {.thread.} =
    waitFor ChatMsg.emit(ChatMsg(user: "Alice", text: "Hello from worker!"))

  var t: Thread[void]
  t.createThread(worker)
  while received.load() < 1:
    await sleepAsync(chronos.milliseconds(1))
  t.joinThread()
  ChatMsg.dropAllListeners()

waitFor main()
```

Compile with `--threads:on`.

---

## Important Notices

### `emit()` is async

The multi-thread `emit()` is an **async** proc (`{.async: (raises: []).}`):

- In async contexts (e.g. inside `{.async.}` procs): use `await emit(...)`.
- In `{.thread.}` procs with no event loop: use `waitFor emit(...)` — this creates
  a temporary event loop for the duration of the call.
- **Same-thread listeners**: dispatched via `asyncSpawn` (fire-and-forget).
- **Cross-thread listeners**: delivered via a per-bucket lock-free Vyukov MPSC ring + `fireBrokerSignal` (near-instant, no OS fds consumed).

### Thread procs cannot be closures

Nim `{.thread.}` procs cannot capture GC-managed variables from outer scopes. Use
module-level globals (with `Atomic` for synchronization) for communication between
threads. However, **listener callbacks** passed to `listen()` can freely capture
variables from the registering thread's scope — they are stored in threadvars and
called locally on that thread.

### `dropListener` is thread-local

`dropListener(handle)` must be called from the **same thread** that registered the
listener. The handle carries a `threadId` field that is validated at runtime.
Calling from the wrong thread logs an error and returns without action.

`dropListener` is **synchronous**: it removes the handler from the thread-local
table and returns immediately. Already-dispatched `asyncSpawn` futures from a
prior `emit` cycle continue to run until they complete — `dropListener` does not
wait for them. If you are releasing resources that in-flight callbacks may still
reference, wait for pending work to finish before dropping:

```nim
# Safe pattern: let the event loop drain before releasing resources.
await sleepAsync(0)          # yield so in-flight asyncSpawns can finish
MyEvent.dropListener(handle)
connection.close()           # now safe
```

### `dropAllListeners` works from any thread

`dropAllListeners()` can be called from any thread. It:

1. Removes all buckets for the context under a global lock.
2. Cleans up local threadvar entries if the caller owns any for this context.
3. Sends a `CtrlClearListeners` sentinel into each remote thread's ring and fires the shared signal.
4. Each remote thread's `brokerDispatchLoop` poll fn receives the sentinel, clears its own threadvar handler table for the context, and continues running (returns 1 — stays registered for future events from other contexts).

Handler removal on remote threads is **asynchronous** — it happens when the
remote thread's event loop processes the `CtrlClearListeners` sentinel. In-flight
`asyncSpawn` futures that were already dispatched before the message arrives
complete naturally on the remote thread.

### Shutdown safety: in-flight listener futures

The three operations have distinct in-flight guarantees:

| Operation | Stops new dispatches? | Waits for in-flight? |
|-----------|----------------------|----------------------|
| `dropListener` (sync) | Yes — handler removed from table | **No** — in-flight continues |
| `dropAllListeners` (any thread) | Yes — sends `CtrlClearListeners` sentinel | **No** — in-flight continues |
| Context shutdown (`shutdownProcessLoopsForCtx`) | Yes — closes the ring (`ring.closed = true`), poll fn drains and exits | **Yes** — awaits `tvListenerFuts` (5 s timeout) |

**Context shutdown** is the safe teardown path. It sets the ring's
`closed` flag (release-ordered, so the flip is visible to in-flight
emitters that already captured the ring pointer); the poll fn on the
listener thread observes empty + closed, completes a shutdown
`Future[void]`, and self-unregisters (returns 2). The caller then awaits
each shutdown future (up to 5 seconds), waits a 50 ms grace window for
in-flight emit callers, and finally drains any remaining in-flight
listener futures tracked in `tvListenerFuts` before returning. This
guarantees no callbacks are running after the call returns.

The FFI API library lifecycle (`registerBrokerLibrary`) calls
`shutdownProcessLoopsForCtx` automatically on `mylib_shutdown(ctx)`.

---

## Architecture

### Per-Listener-Thread Ring + Global Slab Model

Each thread that registers listeners for a `BrokerContext` gets its own
lock-free Vyukov MPSC `ring` (carrying a slab cell index per slot). All
broker types on a thread share one `ThreadSignalPtr` and one
`brokerDispatchLoop`. A **global per-broker-type slab** holds the actual
event payload bytes; one slab cell is shared across N listener-bucket
rings via atomic refcount, so emit allocates one cell and fans out N
pointer pushes (not N deep copies):

```
Emitter Thread                 Listener Thread A                 Listener Thread B
┌──────────────┐              ┌─────────────────────────────┐   ┌─────────────────────────────┐
│   emit(evt)  │              │  ring A (MPSC, slot=cellIdx)│   │  ring B (MPSC, slot=cellIdx)│
│              │              │                             │   │                             │
│  claim 1 cell│──cellIdx+sig▶│                             │   │                             │
│  refcount=2  │──cellIdx+sig─│                             │──▶│                             │
│  marshal evt │              │  brokerDispatchLoop (shared)│   │  brokerDispatchLoop (shared)│
└──────┬───────┘              │    ↓ poll fn tryDequeue     │   │    ↓ poll fn tryDequeue     │
       │                      │  unmarshal evt; dispatch    │   │  unmarshal evt; dispatch    │
       ▼                      │  decRef cell                │   │  decRef cell                │
  Global Slab (per            │  listener1(evt)             │   │  listener3(evt)             │
  broker-type, shared)        │  listener2(evt)             │   │                             │
                              └─────────────────────────────┘   └─────────────────────────────┘

fd count: 2 per thread (one shared ThreadSignalPtr) regardless of broker type count.
```

### Call Sequence: Cross-Thread Emit

```mermaid
sequenceDiagram
    participant E as Emitter Thread
    participant L as Global Lock
    participant SLAB as Global Event Slab
    participant R as ring (Listener Thread MPSC)
    participant S as ThreadSignalPtr (Listener Thread, shared)
    participant DL as brokerDispatchLoop (Listener Thread)
    participant H as Listener Handler

    E->>L: withLock: collect targets for ctx
    L-->>E: targets[] (one entry per listener-thread bucket)
    E->>SLAB: claim 1 cell; refcount = N targets
    E->>SLAB: marshal evt into cell.bytes
    E->>R: tryEnqueue(cellIdx)
    Note over E: returns immediately (bounded ring with backpressure)
    E->>S: fireBrokerSignal

    S->>DL: wakes up
    DL->>R: tryDequeue() → cellIdx
    DL->>SLAB: read+unmarshal cell.bytes → evt on listener heap
    DL->>H: asyncSpawn notifyListener(cb, evt)
    DL->>SLAB: decRef cell (last decRef returns cell to slab)
    Note over DL: in-flight future tracked in tvListenerFuts
```

### Call Sequence: Same-Thread Emit

```mermaid
sequenceDiagram
    participant E as Emitter (same thread)
    participant L as Global Lock
    participant TV as Threadvar Handlers
    participant H as Listener Handler

    E->>L: withLock: detect same-thread target
    L-->>E: isSameThread = true
    E->>TV: read local handler table
    TV-->>E: callbacks[]
    E->>H: asyncSpawn notifyListener(cb, evt)
    Note over E: no channel involved
```

### Call Sequence: dropAllListeners (Cross-Thread)

```mermaid
sequenceDiagram
    participant Caller as Caller Thread
    participant L as Global Lock
    participant TV as Caller Threadvars
    participant R as ring (remote MPSC)
    participant S as ThreadSignalPtr (remote, shared)
    participant DL as brokerDispatchLoop (remote)

    Caller->>L: withLock: flip hasListeners=false; collect (ring, sig) per remote bucket
    L-->>Caller: ringsToClear[]
    Caller->>TV: clean local threadvar entries
    Caller->>R: tryEnqueue(CtrlClearListeners sentinel)
    Caller->>S: fireBrokerSignal

    S->>DL: wakes up
    DL->>R: tryDequeue() → CtrlClearListeners
    DL->>DL: clearListeners(ctx) — wipes threadvar handlers
    Note over DL: poll fn returns 1 (keeps running)
    Note over DL: in-flight asyncSpawn futures continue naturally
```

---

## Memory Layout

### Shared State (createShared)

```
gTMtBuckets ─────────┐
                      ▼
  ┌───────────────────────────────────────────────────────────┐
  │ Bucket[0]         │ Bucket[1]         │ Bucket[2]  ...    │
  │ brokerCtx: Default│ brokerCtx: Default│ brokerCtx: ctxA   │
  │ threadId:  0x1000 │ threadId:  0x2000 │ threadId:  0x1000 │
  │ threadGen: 0      │ threadGen: 1      │ threadGen: 0      │
  │ ring: ───────────►│ ring: ───────────►│ ring: ───────────►│
  │ active:    true   │ active:    true   │ active:    true   │
  │ hasListeners: true│ hasListeners: true│ hasListeners: true│
  └───────────────────────────────────────────────────────────┘

  Plus, separately: gTMtSlab — global per-broker-type payload slab
  (createShared once, lazy-init on first listen/emit, holds refcounted
  cells shared across all bucket rings).
  gTMtBucketCount = 3
  gTMtLock = Lock (protects all shared arrays)
```

Multiple buckets can share the same `BrokerContext` — one per listener thread.
This is the key structural difference from `RequestBroker(mt)` (which has one
bucket per context).

### Thread-Local State (threadvars)

```
Thread 0x1000:
  gTTvListenerCtxs    = [Default, ctxA]
  gTTvListenerHandlers = [Table{1: cb1, 2: cb2}, Table{1: cb3}]
  gTTvNextIds          = [3, 2]

Thread 0x2000:
  gTTvListenerCtxs    = [Default]
  gTTvListenerHandlers = [Table{1: cb4}]
  gTTvNextIds          = [2]
```

Parallel sequences: index `i` maps a `BrokerContext` to its handler table and
next-ID counter for this thread.

---

## Performance

Benchmark results from `nimble perftest` (5 emitter threads × 500 events, 512B payload):

| Metric | Cross-Thread (debug) | Same-Thread (debug) |
|--------|---------------------|---------------------|
| Throughput | ~50K evt/s | ~29K evt/s |
| Avg latency | ~23 ms* | ~34 µs |
| Min latency | ~160 µs | ~20 µs |

*Cross-thread average latency is high in debug builds due to sequential channel processing
under load from 5 concurrent emitters. Release builds with `--mm:orc` see significantly
lower latencies.*

**Optimization notes:**

- Use `--mm:orc -d:release` for production. The hot path is allocation-
  free regardless of MM (atomic claim of a pre-allocated slab cell +
  memcpy/marshal + atomic ring push); release-mode optimizations
  primarily help the marshaler and `asyncSpawn` machinery.
- Same-thread delivery is essentially free (direct `asyncSpawn`, no locking on the hot path, no slab/ring touched).
- Each listener thread has its own MPSC ring and shared `brokerDispatchLoop` — listener throughput scales with the number of listener threads.
- `emit()` holds the global lock only long enough to copy the target list (snapshot pattern).
- **Zero OS fds per broker type** — the ring is a pure user-space lock-free queue, slab is `createShared` memory. Adding more broker types never increases fd count.
- **Fan-out is one alloc, N pointer pushes** — one slab cell shared across N listener-bucket rings via atomic refcount, not N independent deep-copies of the payload.

---

## Comparison with Single-Thread EventBroker

| Feature | `EventBroker:` | `EventBroker(mt):` |
|---------|---------------|-------------------|
| Cross-thread emit | ✗ | ✓ |
| Cross-thread listen | ✗ | ✓ |
| `emit()` return type | void (asyncSpawn) | Future[void] (async) |
| Transport overhead | None | Per-bucket lock-free ring + global slab (per broker type) |
| `dropListener` scope | Any (thread-local broker) | Must be from registering thread |
| `dropListener` in-flight drain | No — in-flight continues | No — in-flight continues (sync, immediate) |
| `dropAllListeners` scope | Any (thread-local broker) | Any thread (sends `CtrlClearListeners` sentinel, no drain) |
| BrokerContext support | ✓ | ✓ |
| Field-constructor emit | ✓ | ✓ |

---

## Compile Flags

```
nim c --threads:on --mm:orc your_app.nim    # recommended
nim c --threads:on --mm:refc your_app.nim   # also supported
```

Debug macro output:
```
nim c -d:brokerDebug --threads:on ...
```
