# Round 2 Part D — EventBroker(API) Dispatch Rework

Status: **DRAFT / proposal** — not yet approved for implementation.
Replaces the §3 sketch in `doc/CBOR_Refactoring_Round2.md`.
Companion: `doc/Event_Dispatch_Options.md` (the options-survey doc).

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
| `brokers/internal/api_event_broker_cbor.nim` | Per-event emit wrapper splits into the three lanes shown in §5. Foreign subscribe/unsubscribe stop posting to the MT EventBroker; they go into the new `foreignSubs` table + atomic counter. |
| `brokers/api_library.nim` (event installer + courier infrastructure) | Add `eventCourier` ring + signal per library, mirror of the request courier. `eventCourierPoll` registered on the delivery thread via the existing `registerBrokerPoller`. Subscribe/unsubscribe entry points update the atomic counter. |
| `brokers/internal/mt_event_broker.nim` | **No changes.** The MT EventBroker continues to serve pure-Nim listeners unmodified. The FFI lane forks upstream of it. |
| `brokers/internal/api_event_broker.nim` (single-thread) | **No changes.** Same-thread Nim listeners still hit the direct-dispatch path in the MT broker's same-thread arm; nothing for the single-thread broker module to do. |
| `test/typemappingtestlib/typemappingtestlib.nim` | No source change; existing parity tests cover the FFI lane and the same-thread Nim lane already. New tests added in `test/ffibench/` for stress + shutdown (see §9). |

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
| Atomic counter / table inconsistency (counter says > 0 but table is empty by the time delivery dequeues) | low | Delivery-side empty snapshot already handled (§6); pay one wasted encode + one wasted enqueue, no correctness issue. |
| Subscriber unregisters during in-flight emit; callback fires anyway | low | Same "snapshot-and-clone" semantics the single-thread broker already documents; expected. |
| Reentrant `_call` from a foreign callback while the callback is still on the delivery thread | low | Request courier is a separate ring serviced by the processing thread; no shared structure with the event courier; no deadlock by construction (already validated by the request side). |
| CBOR encode cost on the provider thread under heavy emit load | med | Symmetric to the request side (encode response on processing thread). Phase 0 microbenchmark must extend to events; ship Part D with the bench numbers attached. |
| Bounded ring overflow under burst load | med | Drop with diagnostic + counter; emit-side surfaces an `err(...)` to the caller (events are fire-and-forget so this is informational). Document the new sentinel. |
| Shutdown ordering — provider emits during teardown drain | high | Per-bucket "shutting down" atomic flag, checked emit-side before enqueuing. Once set, drain runs to completion without races. Stress test `stress_event_shutdown.cpp` must validate this under ASAN + `--mm:refc` and `--mm:orc`. |
| Performance regression for pure-Nim audience due to the atomic-counter load | very low | One acquire-load per emit. Measurable in a tight loop but in absolute terms is sub-nanosecond on modern x86 / ARM. Acceptable. |

## 11. Sequencing & effort

Suggested commit-grain inside the branch:

| # | Sub-phase | Scope | Effort |
|---|---|---|---|
| 1 | D-i | Add `EventCourierMsg`, per-library ring + signal infrastructure in `api_library.nim`; register the new poller on the delivery thread. No subscriber-side wiring yet — ring is dormant. | 0.5 d |
| 2 | D-ii | Add `foreignSubs` table + atomic counter to the per-event bucket; rewrite `foreignSubscribe/Unsubscribe` to update them; old MT-broker-routed subscribe code becomes the Nim lane only. Existing tests must still pass — only the storage moves, not the semantics. | 1 d |
| 3 | D-iii | Rewrite per-event emit wrapper (`api_event_broker_cbor.nim`) into the three-lane shape (§5). Lane 3 actually encodes + enqueues now. Existing parity matrix must stay green. | 1.5 d |
| 4 | D-iv | Add `stress_event_no_foreign.cpp`, `stress_event_no_nim.cpp`, `stress_event_mixed_audience.cpp`. | 0.5 d |
| 5 | D-v | Shutdown drain: bucket "shutting down" flag, ring drain in `<lib>_shutdown`, lifecycle stress driver. Run under ASAN + valgrind, both `--mm:` modes. | 1.5 d |
| 6 | D-vi | Extend the bench harness to events; capture before/after numbers for the mixed-audience case + the pure-Nim case (regression check). Update `doc/bench_baseline.md`. | 0.5 d |
| 7 | D-vii | Doc sweep: update `doc/CBOR_Refactoring_Round2.md` to point at this doc; update `doc/FFI_API.md` banner / event sections. | 0.5 d |

Total ≈ **6 days** including the stress drivers and the bench.

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
