# Round 2 Part D — EventBroker(API) Dispatch Rework

Status: **DRAFT / proposal** — revised. Replaces the §3 sketch in
`doc/CBOR_Refactoring_Round2.md`. Companion:
`doc/Event_Dispatch_Options.md` (options-survey doc).

> **Revision note (mandatory read):** the original Part D plan assumed
> the per-context delivery thread already existed in the CBOR impl. It
> does not. The delivery thread was implemented exclusively inside
> `registerBrokerLibraryNativeImpl` on master; the CBOR impl never had
> one. When Phase 2 commit [c18896d] retired the native impl by
> deleting that proc body (a 1080-line `sed` range), the delivery
> thread infrastructure went with it. The current branch runs every
> event handler — including the CBOR encode + foreign-callback fan-out
> — on the **processing thread**, inline with the provider that
> emitted the event.
>
> This violates the maintainer's stated invariant ("delivery thread is
> a must-have for all event broker API") and creates a real
> provider-blocking hazard: a slow foreign callback stalls the request
> providers it shares a thread with. Part D therefore *first restores
> the delivery thread*, then *moves event handlers onto it*, and
> *only then* applies the courier optimization on top.
>
> The redesign reshapes the sequencing (§11) but the architectural
> goal (three lanes, atomic-counter fast path, encode-once-on-emit
> for the FFI fanout) is unchanged.

## 1. The contract we must preserve

`nim-brokers` is a **general-purpose** messaging library; the
`(API)` variants do not narrow the audience. Any combination of
listener kinds must compose cleanly without the user touching the
emit-site or the broker declaration:

- Single-thread Nim use → behaves like the plain `EventBroker`
  (direct `asyncSpawn`, no slab, no encode).
- Cross-thread Nim use → MT EventBroker as today (typed slab + signal
  per destination thread).
- FFI use → foreign callback delivered on the delivery thread.
- **All of the above on the same broker, at the same time.**

The dominant production shape (≈ 90 % by the maintainer's estimate)
is: provider runs on the library's processing thread; one or more
**same-thread Nim listeners** consume the event there; one or more
**foreign callbacks** also consume it via the FFI ABI. Round 2 Part D
must make that case cheap.

## 1a. Baseline — what the CBOR-only branch actually does today

Confirmed by file-level audit of `brokers/api_library.nim` on
`retire-native-cbor-optimize`:

| Concern | Master (pre-Phase 2) | Current branch |
|---|---|---|
| Threads per context | processing + delivery | **processing only** |
| Where `installAllListeners(ctx)` runs | delivery thread | processing thread (line 719) |
| Where per-event handler closure runs | delivery thread | processing thread (same-thread MT-broker fast path — no slab) |
| Where foreign-callback fan-out fires | delivery thread | processing thread (inline, blocking) |
| `RegisterEventListenerResult` synthetic broker | emitted | **not emitted** — `<lib>_subscribe` writes the shared `subsRegistry` directly under its own lock |
| Per-event `cleanup` / `processLoop-shutdown` proc-name accumulators | populated | empty (no native event broker codegen left to populate them) |
| Subscriber registry storage | `subsRegistry` (shared heap, dedicated lock) | unchanged |

Concrete consequences of the missing delivery thread:

- **Provider blocking**: a foreign callback that takes 100 ms blocks
  request providers for 100 ms on the same processing thread.
- **Reentrancy hazard**: a foreign callback that calls back into
  `<lib>_call` enqueues onto the request courier ring — handled by
  the same thread that's currently mid-callback. The courier poller
  doesn't run until the callback returns, so the nested `_call`
  waits on its response slot for a request that can't be serviced
  until control returns to the dispatch loop. This is the textbook
  reentrancy-into-self deadlock the dedicated delivery thread
  exists to prevent.
- **Provider-side latency**: every event whose payload contains
  `seq[T]` / `string` pays a Nim-side allocation (the `cborEncode`
  inside `cborEncodeShared`) inline on the provider thread, even
  when no foreign subscriber exists. (Cf. the atomic-counter
  fast-path proposed below — it pays nothing in that case.)

The parity tests pass on this state because they don't probe slow
callbacks or reentrant `_call`-from-callback. Pre-merge stress
drivers (D-5) will exercise both.

## 2. The three dispatch lanes

For a single `.emit(payload)` on emit-thread `T`:

```
                   ┌─────────────────────────────────────┐
                   │   .emit(payload) on thread T        │
                   └────────────┬────────────────────────┘
                                │
                                ▼
                  ┌──────────── snapshot under bucket lock ────────────┐
                  │   nimListenersByThread : Table[Thread,seq[Handler]]│
                  │   foreignSubsCount     : Atomic[int]   (lock-free) │
                  └──────────────────┬─────────────────────────────────┘
                                     │
            ┌────────────────────────┼──────────────────────────────────┐
            ▼                        ▼                                  ▼
  Lane 1                  Lane 2                            Lane 3
  same-thread Nim         cross-thread Nim                  FFI fanout
  (T == listener thread)  (T != listener thread)            (any listener thread)

  for l in listeners:     marshal typed payload into        if foreignSubsCount > 0:
    asyncSpawn l(payload) target thread's MT slab cell,      buf = cborEncodeShared(payload)
                          fire MT signal                     enqueueEventCourier(buf, len)
                                                             fireCourierSignal
  no allocation           one slab cell per dest thread,     one shared-heap buffer,
  no encode               typed copy in/out                  one CBOR encode
```

Properties that fall out:

- Same-thread Nim listeners cost the same as the single-thread broker.
- Cross-thread Nim listeners cost exactly the same as today's MT
  EventBroker (no change).
- FFI fanout costs one CBOR encode per emit (not per subscriber) and
  one cross-thread crossing total, regardless of subscriber count.
- A broker with no FFI subscribers right now pays **zero** for the FFI
  lane — the atomic counter check short-circuits before the encode.

## 3. Per-bucket data structures

The MT EventBroker bucket gains two siblings to its existing typed
listener table:

```nim
type
  ForeignSubEntry = object
    handle: uint64
    callback: ForeignEventCallback   # the C ABI function pointer
    userData: pointer

  EventBucket = object
    # — existing —
    lock: Lock
    nimListeners: Table[uint64, NimHandler]
      ## keyed by registration handle; values include the listener's
      ## thread (existing MT EventBroker concept).

    # — added by Part D —
    foreignSubs: Table[uint64, ForeignSubEntry]
      ## delivery-thread-owned writer; readable from delivery thread
      ## only. Emit-side never reads this field.
    foreignSubsCount: Atomic[int]
      ## written by foreignSubscribe/Unsubscribe under bucket.lock;
      ## read lock-free by every emit-side caller. moRelease on write,
      ## moAcquire on read.
```

The atomic counter is the **only** field the emit thread reads to
decide whether the FFI lane is live. The `foreignSubs` table itself is
read only on the delivery thread, where it does not need any
synchronization beyond the bucket lock that already covers
subscribe/unsubscribe.

## 4. Subscribe / unsubscribe path

```nim
# Called from any foreign thread (the FFI ABI's <lib>_subscribe).
# Routes through the delivery thread for the actual table mutation —
# delivery thread is the single writer.
proc foreignSubscribe(bucket: ptr EventBucket, cb, userData): uint64 =
  withLock(bucket.lock):
    let handle = nextHandle()
    bucket.foreignSubs[handle] = ForeignSubEntry(handle, cb, userData)
    bucket.foreignSubsCount.fetchAdd(1, moRelease)
    return handle

proc foreignUnsubscribe(bucket: ptr EventBucket, handle: uint64) =
  withLock(bucket.lock):
    if bucket.foreignSubs.pop(handle, _):
      bucket.foreignSubsCount.fetchSub(1, moRelease)
```

Memory ordering:
- Producer (subscribe) does `fetchAdd(release)` — pairs with the
  consumer's `load(acquire)` on the emit side.
- Race-free pattern: see "Acquire-Release" in the C++ memory model,
  same as Nim's `std/atomics`.

The counter is conservative: a transient over-count (emit observes 1
but the subscriber unsubscribed concurrently) results in one wasted
CBOR encode for that emit — the delivery thread re-snapshots
`foreignSubs` and finds it empty, dropping the buffer cleanly. A
transient under-count (emit observes 0 but a subscriber just
registered) means the just-registered subscriber misses this one event
— consistent with the existing "snapshot-and-clone" semantics of the
single-thread broker.

## 5. Emit dispatch

```nim
# Generated by the EventBroker(API) macro, per event type.
proc emitImpl(payload: T) =
  let emitThread = getCurrentThreadId()

  # — snapshot Nim listeners (unchanged MT broker code path) —
  let nimByThread = snapshotNimListenersByThread(bucket)

  # — FFI lane: lock-free fast-path —
  let needForeignFanout = bucket.foreignSubsCount.load(moAcquire) > 0

  # Lanes 1+2: Nim listeners (identical to today's MT EventBroker)
  for (thread, listeners) in nimByThread:
    if thread == emitThread:
      for l in listeners:
        asyncSpawn l(payload)
    else:
      marshalIntoSlab(payload, thread)
      fireMtSignal(thread)

  # Lane 3: FFI fanout via courier
  if needForeignFanout:
    let buf = cborEncodeShared(payload)
    let msg = EventCourierMsg(
      eventTypeId: thisEventTypeId,
      ctx: thisCtx,
      buf: buf,
      len: buf.len,
    )
    if not eventCourier.ring.tryEnqueue(msg):
      # Bounded ring; drop with diagnostic. Same backpressure shape
      # the request courier defines.
      deallocShared(buf)
      logFfiEventDrop(thisEventTypeId)
    else:
      eventCourier.signal.fireSync()
```

Key invariants:
- The bucket lock is held only for the snapshot. Encode + enqueue
  happen outside.
- One CBOR encode per emit, **not per subscriber**.
- If `needForeignFanout == false`, no encode, no allocation, no ring
  touch. The 90 % production case where every emit happens to have
  zero foreign subscribers for this emit cycle pays nothing.

## 6. Delivery-side fanout

```nim
# Registered on the delivery thread's brokerDispatchLoop (the same
# poller infrastructure the request courier uses, mt_broker_common.nim).
proc eventCourierPoll() =
  while true:
    var msg: EventCourierMsg
    if not eventCourier.ring.tryDequeue(msg): break

    # Snapshot foreign subscribers locally — delivery thread is the
    # sole writer, no cross-thread coordination needed.
    let subs = bucket(msg.eventTypeId, msg.ctx).foreignSubs.snapshot()

    if subs.len == 0:
      # Subscribers all unsubscribed between emit and delivery —
      # drop cleanly.
      deallocShared(msg.buf)
      continue

    # Synchronous fanout. Foreign callbacks are not async; the
    # delivery thread runs them serially. After all return, free.
    for sub in subs:
      invokeForeignCallback(sub.callback, msg.ctx, eventName(msg.eventTypeId),
                            msg.buf, msg.len, sub.userData)
    deallocShared(msg.buf)
```

No atomic refcount needed because the fanout is synchronous on a
single thread. After the final callback returns the buffer has no
references; deallocate immediately. (Contrast with the request
courier, which only has one consumer per buffer — symmetric
simplicity.)

## 7. Shutdown

Mirrors the request courier discipline (round 1 §6.4):

1. `<lib>_shutdown(ctx)` arrives on the foreign thread; it dispatches
   the shutdown request to the processing thread (same path as today).
2. Processing thread:
   - Stops accepting new `.emit` enqueues (set a per-bucket atomic
     flag; emit-side checks it after the foreignSubsCount probe).
   - Drains the event courier ring: for each pending message, free
     the buffer without invoking callbacks.
3. Delivery thread teardown:
   - Drain any in-flight foreign callbacks (synchronous; they run to
     completion).
   - Free the foreign subscriber table.
4. Free per-bucket structures.

The drain step matters for ASAN cleanliness — a leaked buffer at
process exit is identical to a logic bug.

## 8. Codegen impact

Files touched, in approximate order of edit volume:

| File | Change |
|---|---|
| `brokers/api_library.nim` (event installer + courier infrastructure) | Per-event handler (`api_library.nim:540-599`) splits into the three lanes shown in §5. Add `eventCourier` ring + signal per library, mirror of the request courier. `eventCourierPoll` registered on the delivery thread via the existing `registerBrokerPoller`. Subscribe/unsubscribe entry points update the atomic counter. `dropAllListeners` hook clears foreign subs via `subsRegistryRemoveAllForKey` + resets `foreignSubsCount` (see §8a). |
| `brokers/internal/api_event_broker_cbor.nim` | **Compile-time only** — no runtime code. Registers event entries in `gApiCborEventEntries` for `api_library.nim` to wire at `registerBrokerLibrary` expansion time. No Part D changes needed. |
| `brokers/internal/mt_event_broker.nim` | **No changes.** The MT EventBroker continues to serve pure-Nim listeners unmodified. The FFI lane forks upstream of it. |
| `brokers/internal/api_event_broker.nim` (single-thread) | **No changes.** Same-thread Nim listeners still hit the direct-dispatch path in the MT broker's same-thread arm; nothing for the single-thread broker module to do. |
| `test/typemappingtestlib/typemappingtestlib.nim` | No source change; existing parity tests cover the FFI lane and the same-thread Nim lane already. New tests added in `test/ffibench/` for stress + shutdown (see §9). |

## 8a. `dropAllListeners` and FFI subscriber cleanup

The MT EventBroker's `dropAllListeners` is **synchronous and callable
from any thread** (`mt_event_broker.nim:683`). It clears same-thread
`tvHandlers` immediately and sends a `CtrlClearListeners` sentinel to
cross-thread buckets. However, it has **no awareness of `SubsRegistry`**
— foreign subscriber entries survive the drop.

After `dropAllListeners` without cleanup:
- The MT EventBroker listener (the handler at `api_library.nim:559`
  that does `subsRegistrySnapshot` → CBOR encode → foreign callback
  fanout) is removed.
- But `SubsRegistry` still holds the `SubNode` entries — orphaned.
  No foreign callback fires (the handler that reads them is gone), but:
  - `foreignSubsCount` stays > 0 → emit fast-path still tries to
    encode + enqueue into the courier for nothing.
  - Stale `SubNode` entries leak until `_shutdown` calls
    `subsRegistryFreeForCtx`.

**Fix (wired in D-3):** Each per-event installer in `api_library.nim`
registers a companion cleanup hook. When `dropAllListeners` fires for
a given `(ctx, eventType)`, the hook calls
`subsRegistryRemoveAllForKey(subsReg, ctx, eventName)` and resets the
per-event `foreignSubsCount` atomic to 0. This is safe under the
existing `SubsRegistry` lock — no delivery-thread dispatch needed,
just a registry mutation.

The hook is naturally per-event-type because the MT EventBroker's
generated `dropAllListenersImpl` is type-specific — each knows its own
event name at codegen time.

## 9. Test plan

Existing matrices must stay green:
- `nimble testApiCbor` — full 4-axis (orc/refc × debug/release).
- `nimble runTypeMapTestLibCborCpp` — 119/119.
- `nimble runFfiExampleCborCpp` / `Py` / `Rust` / `Go` — end-to-end.

New tests for Part D, all in `test/ffibench/`:

| Test | What it proves |
|---|---|
| `stress_event_mixed_audience.cpp` | Same broker, K same-thread Nim listeners + M cross-thread Nim listeners + N foreign callbacks; emit at sustained rate; assert every audience receives every event (modulo single-window subscribe race). |
| `stress_event_no_foreign.cpp` | Pure-Nim audience; assert zero CBOR encodes happen (instrument allocShared calls). The atomic fast-path discriminator must short-circuit. |
| `stress_event_no_nim.cpp` | Pure-foreign audience; assert MT slab is not touched (instrument the bucket's slab counter). |
| `stress_event_shutdown.cpp` | Emit at sustained rate, call `<lib>_shutdown(ctx)` mid-stream from another thread; assert every queued buffer is freed exactly once, no UAF, no leaked callbacks. Run under ASAN. |
| `stress_event_subscribe_race.cpp` | Foreign threads register/unregister callbacks while emits are in flight; assert no double-free, no use-after-free, no double-invocation of the same handle. |

The first three tests are the meat of the mixed-audience claim: they
prove the three lanes can coexist without cross-talk and that absent
audiences cost nothing.

## 10. Risk register

| Risk | Severity | Mitigation |
|---|---|---|
| **D-1 thread-lifecycle restoration introduces an ASAN/valgrind regression** | **high** | The deleted native impl had subtle teardown ordering (drain processLoops → drop listeners → drain pending ring frees). Need to verify whether those ordering constraints apply to the CBOR impl too. If yes, mirror them; if no (e.g. because CBOR doesn't have per-event processLoops), document the difference. Read the deleted native delivery-thread proc body in master (`brokers/api_library.nim:759-810` on `chore/jovial-northcutt-ba2ccc`) before writing D-1. |
| **D-2 changes the dominant cost path** — every event with a foreign subscriber now pays an MT-slab marshal+unmarshal where today it pays nothing (same-thread fast path) | med (transient) | Acknowledged as a one-commit regression. D-3 strictly improves on it. If D-3 slips, the user must be aware that D-2-alone is a net cost. Tie D-2 + D-3 into a milestone branch merge if needed. |
| Atomic counter / table inconsistency (counter says > 0 but table is empty by the time delivery dequeues) | low | Delivery-side empty snapshot already handled (§6); pay one wasted encode + one wasted enqueue, no correctness issue. |
| Subscriber unregisters during in-flight emit; callback fires anyway | low | Same "snapshot-and-clone" semantics the single-thread broker already documents; expected. |
| Reentrant `_call` from a foreign callback fires the request courier from the delivery thread; processing thread services it — **but only if the delivery thread is not the same as the processing thread** | med | This is the entire reason D-1 exists. Today (no delivery thread) the reentrant `_call` deadlocks. After D-1 the call goes to a separate thread and is serviced normally. Stress test `stress_event_reentrant.cpp` (added in D-5) must validate this. |
| Slow foreign callback blocks request providers | high (today) → resolved (after D-2) | Slow-callback test in D-5: callback sleeps 100 ms; assert request providers continue servicing requests at the same throughput. Failing this test fails the merge. |
| CBOR encode cost on the emit thread under heavy emit load | med | Symmetric to the request side (encode response on processing thread). Phase 0 microbenchmark extension (D-6) must show the encode is bounded and amortized. |
| Bounded ring overflow under burst load | med | Drop with diagnostic + counter; emit-side surfaces an `err(...)` to the caller (events are fire-and-forget so this is informational). Document the new sentinel. |
| Shutdown ordering — provider emits during teardown drain | high | Per-bucket "shutting down" atomic flag, checked emit-side before enqueuing. Once set, drain runs to completion without races. Stress test `stress_event_shutdown.cpp` must validate this under ASAN + `--mm:refc` and `--mm:orc`. |
| Performance regression for pure-Nim audience due to the atomic-counter load | very low | One acquire-load per emit. Measurable in a tight loop but in absolute terms is sub-nanosecond on modern x86 / ARM. Acceptable. |
| Delivery thread join blocks on a stuck foreign callback at shutdown | med | The delivery-thread shutdown sequence must drain pending fanouts first, but in-flight foreign callbacks return on their own. If a foreign callback hangs (faulty integration), shutdown hangs too — but that's a foreign-side bug, not ours. Document in `doc/FFI_API.md` so integrators know callbacks must be bounded-time. |
| `dropAllListeners` leaves orphaned foreign subs in `SubsRegistry` | med | MT EventBroker's `dropAllListeners` is synchronous, callable from any thread, and has no awareness of `SubsRegistry`. Without cleanup, `foreignSubsCount` stays > 0 (wasted encodes) and `SubNode` entries leak until `_shutdown`. D-3 wires a per-event cleanup hook that calls `subsRegistryRemoveAllForKey` + resets the atomic counter. See §8a. |

## 11. Sequencing & effort

Revised commit-grain. The first two phases (D-1, D-2) restore the
delivery thread to the CBOR impl, which is a prerequisite the original
plan missed. After D-2 the architecture matches what master had (event
handlers on a dedicated thread) **without any courier work yet**. D-3
then applies the courier optimization on top.

| # | Sub-phase | Scope | Effort |
|---|---|---|---|
| 1 | **D-1 Restore delivery thread (no behavior change yet)** | Per-context delivery thread spawned by `<lib>_createContext` *before* the processing thread (so listeners are live before any emit can fire). Mirror master's pattern (`delivThreadArgIdent`, `delivThread: Thread[...]`, `deliveryReady: Atomic[int]` on `startupState`). Body: `setThreadBrokerContext(ctx)` → await shutdown (chronos sleep loop) → on shutdown drain + free. No event handlers move yet — the thread is created and joined but does nothing else. `<lib>_shutdown` flips `shutdownFlag`, joins both threads in the right order (delivery first, then processing — mirrors master). Existing tests must pass unchanged. | 1.5 d |
| 2 | **D-2 Move event handlers to delivery thread** | `installAllListenersIdent(arg.ctx)` moves from processing-thread body (api_library.nim:719) to delivery-thread body. Per-event handler closure (`api_library.nim:540-599`) now runs on the delivery thread. Provider `.emit` on the processing thread becomes genuinely cross-thread — MT EventBroker takes its typed-slab cross-thread path for every event with a foreign subscriber. **Slow foreign callbacks no longer block the provider.** This is the architectural restoration; cost-wise it's neutral-to-slightly-worse than D-1 baseline (MT slab is now exercised where the same-thread fast path used to apply). Existing parity matrix must stay green. | 1 d |
| 3 | **D-3 Event courier ring + atomic-counter fast path + `dropAllListeners` cleanup** [shipped] | Add `brokers/internal/api_cbor_event_courier.nim` (mirror of `api_cbor_courier.nim` minus the response-slot machinery — events are fire-and-forget). Per-context `eventCourier: ptr CborEventCourier` allocated in `_createContext`, freed in `_shutdown` after both threads join. Add `foreignSubsCount: Atomic[int]` updated on subscribe/unsubscribe via the existing `subsRegistry` lock. Rewrite the per-event handler so the FFI fan-out goes through the courier ring (encode-once-on-emit-thread, opaque buffer crosses, delivery thread dequeues + fans out). Nim listeners keep going through MT EventBroker (Lane 1/2 unchanged). **Also wire `dropAllListeners` cleanup (§8a):** each per-event installer registers a companion hook so that when the MT EventBroker's `dropAllListeners` fires, it also calls `subsRegistryRemoveAllForKey` + resets `foreignSubsCount` for that event type. Existing parity matrix stays green. | 2 d |
| 4 | **D-4 Stress drivers — mixed audience / no-foreign / no-nim** [shipped, correctness-only] | Add `test/ffibench/stress_event_mixed_audience.cpp`, `stress_event_no_foreign.cpp`, `stress_event_no_nim.cpp`. Each asserts the dispatch contract end-to-end: the mixed driver proves all three lanes coexist without cross-talk; no-foreign proves Nim listeners still fire when zero foreign subscribers are registered; no-nim proves the FFI lane fires when zero Nim listeners are registered. **The "zero CBOR encodes" / "MT slab untouched" instrumentation in the original D-4 scope is deferred to D-6 (bench harness)** — D-6 already needs internal counters for the (a)/(b)/(c)/(d) timing breakdown, so the same counters cover D-4's instrumented assertions. The D-4 drivers as shipped are pure correctness gates. Wire into a new nimble task `runFfiBenchEventStress`. | 0.5 d |
| 5 | **D-5 Shutdown drain + ASAN lifecycle stress** | Per-bucket `shuttingDown: Atomic[int]` flag in the event courier; emit-side checks it after the counter probe; `<lib>_shutdown` sets it before draining. Add `stress_event_shutdown.cpp` mirroring `test/ffibench/stress_shutdown.cpp`: emit at sustained rate, call `<lib>_shutdown(ctx)` mid-stream, assert every queued buffer is freed exactly once (ASAN-clean). Run under ASAN + valgrind in both `--mm:orc` and `--mm:refc`. Also add a slow-callback test (callback sleeps 100 ms) confirming the provider thread is not blocked — proves the delivery-thread restoration was actually needed. | 1.5 d |
| 6 | **D-6 Bench harness extension** | Add `test/ffibench/bench_event_driver.cpp` measuring (a) emit-only with no foreign subscribers (atomic-counter fast path), (b) emit + one foreign subscriber (full courier path), (c) emit + N foreign subscribers (fan-out amortization), (d) emit + nim listeners only (Lane 1/2 cost). Capture numbers; extend `doc/bench_baseline.md`. The (a) → (b) delta quantifies the courier's per-call overhead; the (b) → (c) delta quantifies the fan-out efficiency. | 0.5 d |
| 7 | **D-7 Doc sweep** | Update `doc/CBOR_Refactoring_Round2.md` Part D status to "shipped". Sweep `doc/FFI_API.md` event sections referencing the (now-correctly-restored) delivery thread. Refresh `AGENTS.md` two-thread description. Mark this doc "implemented". | 0.5 d |

Total ≈ **7.5 days** — the +1.5 d over the original estimate is the
delivery-thread restoration (D-1) plus the slow-callback test in D-5.

### Phase boundaries — what each commit guarantees

- **After D-1**: branch compiles + all existing tests pass; a delivery
  thread exists but is functionally idle (sleeps awaiting shutdown).
  Bisection-friendly: any test that breaks here breaks because of the
  thread lifecycle plumbing, not because of dispatch changes.
- **After D-2**: branch compiles + all existing tests pass; event
  handlers run on the delivery thread; provider thread no longer
  invokes foreign callbacks inline. Performance is slightly worse
  than pre-D-1 (MT slab now exercised); this is acceptable transient
  state for one commit.
- **After D-3**: branch compiles + all existing tests pass; FFI lane
  has its courier; mixed audience cost is below the pre-D-1 baseline.
  This is where the user-visible performance win lands.
- **After D-4**: stress drivers exist; they pass under non-ASAN.
- **After D-5**: stress drivers pass under ASAN + valgrind in both
  `--mm:` modes; slow-callback test proves the delivery thread does
  its job.
- **After D-6**: numbers are recorded in `doc/bench_baseline.md`.
- **After D-7**: docs reflect the shipped state.

## 12. Explicit non-goals

- **Not touching `RequestBroker(API)`.** Round 1 already gave it the
  courier; Round 2 Part D is event-only. (Request fan-out is degenerate
  — single provider — so the per-emit decision logic doesn't apply.)
- **Not introducing `FASTAPI`.** Still deferred.
- **Not changing the foreign callback wrapper-side decode path.**
  Whatever cbor2 / jsoncons / ciborium / fxamacker code each generated
  wrapper emits — unchanged.
- **Not touching MT EventBroker internals.** The Nim lanes use it
  exactly as today. The FFI lane forks upstream of it.

## 12a. Pre-implementation checklist (for the next session)

Before writing any code, the implementer must answer:

1. **Read the deleted native delivery-thread proc body in master.**
   Concretely: `git show chore/jovial-northcutt-ba2ccc:brokers/api_library.nim`
   and inspect lines 759–810. Two arms exist (`hasCleanup` vs.
   `hasEventHandlers else`); identify which arm applies when the
   CBOR branch's `gApiEventCleanupProcNames` / `gApiEventProcessLoopShutdownProcNames`
   accumulators are empty.

2. **Confirm the empty-accumulator arm is correct for CBOR.** Today
   the CBOR codegen never populates those two accumulators (no
   per-event cleanup procs are generated). The simpler arm of the
   native delivery thread proc (no `cleanupAllIdent`, no
   `shutdownAllProcessLoopsIdent` calls) is therefore the right
   template — confirm by tracing what populates the accumulators on
   master (it's the deleted `api_event_broker.nim`, not the CBOR
   counterpart).

3. **Verify `setThreadBrokerContext(ctx)` is enough for foreign-thread
   GC on the delivery thread**. The delivery thread is a Nim thread
   spawned via `createThread`, not a foreign thread — so
   `ensureForeignThreadGc()` is unnecessary, but verify by reading
   master's delivery-thread proc (it does `setThreadBrokerContext`
   alone).

4. **Decide subscribe/unsubscribe routing.** Today
   `<lib>_subscribe` writes the shared `subsRegistry` directly under
   the registry's lock. That works because the registry is
   thread-safe by construction. The atomic counter
   (`foreignSubsCount`) can be updated *inside the same registry
   lock* — no separate dispatch to the delivery thread needed. The
   master-style "RegisterEventListenerResult RequestBroker" is
   *not* coming back; the direct-registry path is simpler and
   already shipped.

5. **Settle ring sizing.** `newCborEventCourier(1024)` is a
   placeholder. Use the request courier's `64`-slot precedent as a
   starting point unless a stress driver shows burst pressure
   warrants more. Worth re-tuning after D-6 bench numbers land.

6. **Sanity-check `mt_broker_common.nim` poller registration**.
   `registerBrokerPoller` registers on the *current* thread's
   chronos dispatcher. The event-courier poller must run on the
   delivery thread, so the `registerBrokerPoller(eventCourierPoll)`
   call has to live inside the delivery-thread proc body (after
   `setThreadBrokerContext(ctx)`, before `await sleepAsync`). This
   exactly mirrors how the request courier poller is registered
   inside the processing-thread proc body (api_library.nim:791 in
   master, equivalent line in the current branch).

## 12b. Reference state

| Anchor | Location | Use |
|---|---|---|
| Native delivery-thread proc template (read-only reference) | `git show chore/jovial-northcutt-ba2ccc:brokers/api_library.nim` lines 759–810 | D-1 template |
| Request courier module (read-only reference) | `brokers/internal/api_cbor_courier.nim` | D-3 template (drop response slots, keep ring + lifecycle) |
| Request courier wiring in `api_library.nim` (`newCborCourier`, poller registration, shutdown drain) | `brokers/api_library.nim` (current branch) — search `CborCourier` | D-3 wiring template |
| Per-event installer that today does encode + fanout inline | `brokers/api_library.nim:540-599` (current branch) | D-2 + D-3 rewrite target |
| `subsRegistry` API (thread-safe registry of foreign subscribers) | `brokers/internal/api_cbor_subs_registry.nim` | atomic counter lives next to this — D-3 |

> **CWD discipline reminder for the next session**: there is a
> worktree at `/Users/schwarzy/dev/worktrees/nim-brokers/jovial-northcutt-ba2ccc`
> on branch `chore/jovial-northcutt-ba2ccc` (master HEAD). The Part D
> branch is `retire-native-cbor-optimize` in
> `/Users/schwarzy/dev/status/nim-brokers`. Bash CWD silently drifts
> between them across tool calls; **always start with `cd
> /Users/schwarzy/dev/status/nim-brokers && pwd && git branch
> --show-current`** before any grep / wc / sed. Use absolute paths
> with Read/Write to avoid this entirely.

## 13. Open questions (none blocking)

These would refine the design but do not change the shape:

1. **Foreign callback execution time** — if we ever want a "fast"
   variant where callbacks must complete in < 10 µs (so reentrant
   `_call` is impossible by contract), that's a future opt-in tag.
   Not in Part D.
2. **Per-event ring vs. per-library ring** — single ring per library
   is the round-1 default for the request courier and the proposed
   default here. A per-event ring would parallelize fanout across
   event types but complicates the poller. Stay with per-library
   until a profile says otherwise.
3. **Subscriber-list ordering** — single-thread broker delivers in
   registration order; the foreign fanout in §6 iterates the
   `foreignSubs` table which is `Table[uint64, …]` (unordered).
   Make it ordered (`OrderedTable`) if order is observable from the
   foreign side; otherwise leave as `Table`. Cheap to switch.
