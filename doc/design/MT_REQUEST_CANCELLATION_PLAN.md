# MT RequestBroker — explicit cancellation + response-slot reuse hardening

Status: **implemented** (Part A and Part B phases B-1…B-4). This document is
kept as the design record — the "current state" table and the risk analyses
describe the code *before* the change, the fixes describe what landed.

Implementation map:

| Piece | Where |
|---|---|
| Packed `(gen, state)` control word, `beginWrite`/`abandonIfGen`/`readyState`/`isAbandoned`/`slotGen`, waker slot, `cancelEpoch` | `brokers/internal/mt_queue.nim` |
| `ReqWaitState` (retirement/reaping contract) | `brokers/internal/mt_broker_common.nim` |
| `responseSlotGen` on `ReqMsg`, generation-checked `sendReply`, `giveUp<T>`, prologue/tail split, `requestCancellable` / `blockingRequestCancellable` / `cancel`, in-flight registry + epoch-gated scan, pre-start drop | `brokers/internal/mt_request_broker.nim` |
| Regression gates | `test/test_mt_request_slot_lifecycle.nim` (A-1/A-2/A-3), `test/test_mt_request_cancel.nim` (B) |

Two independent workstreams that share one prerequisite (slot generation
counter).

* **Part A** — the response-slot reuse hazard (correctness bug that exists
  today, on the timeout path).
* **Part B** — explicit, caller-driven cancellation of a cross-thread request.

Part A must land first: Part B's request id is only ABA-safe once slots carry
a generation counter, and Part B multiplies the number of
give-up-before-reply events (today only a 5 s timeout produces one).

## Decisions taken (review, this round)

| # | Decision | Consequence |
|---|---|---|
| D1 | **Pack `state + gen` into one `Atomic[uint64]`** | all slot transitions become a single CAS on the pair; no gen/state re-read retry logic; `mt_queue.nim`'s four state helpers are rewritten, their call sites are not. Closes R6 by construction |
| D2 | **Safest handle, non-GC**: opaque `uint64` request id = `slotIdx<<32 or gen`, issued by a *synchronous prologue* | no caller-allocated token, no refcount, no destructor hooks, no refc/ORC divergence, nothing to free; a stale id is a gen-mismatched no-op. Supersedes the caller-allocated token sketched in the first draft |
| D3 | **Pre-start drop is in scope** | a cancelled *or timed-out* request that has not yet been dispatched is dropped at the consumer instead of executed. Semantic change — changelog + `doc/MultiThread_RequestBroker.md` |

---

## 0. Current state (reference)

| Concern | Where | Behaviour today |
|---|---|---|
| Enqueue | `mt_request_broker.nim:936` `sendAndAwait<T>` | claim slot → claim slab cell → marshal `ReqMsg` → `ring.tryEnqueue` → `fireBrokerSignal(providerSignal)` |
| Provider dequeue | `mt_request_broker.nim:735` poll fn | `tryDequeue` → unmarshal → `asyncSpawn handleMsg` (future discarded) → `slab.release` |
| Reply | `mt_request_broker.nim:532` `sendReply<T>` | CAS `Empty→Writing`; on failure (requester abandoned) **the provider releases the slot** |
| Requester wait | `mt_request_broker.nim:1005-1050` | one-shot poller on `readyState` + `await withTimeout(fut, gTMtTimeout)` |
| Timeout | same | `cancelSoon()` + `discard pool.abandon(slot)` + `err(...)`; **poller is never deregistered** |
| Sync wait | `mt_request_broker.nim:1131` | busy-poll `readyState` with `sleep(1)`; on deadline `discard pool.abandon(slot)` + `err(...)` |
| Slot states | `mt_queue.nim:433` | `Empty / Writing / Ready / Abandoned` |

Invariant the code intends (stated in `sendReply`'s comment and the
`mt_queue.nim:414` state-machine diagram): **a slot returns to the free list
exactly once, and the side that loses the `Empty→…` CAS race does the
release.**

---

## Part A — response-slot reuse hazard

### A.1 The defects

**A-1 (stale poller / stolen response).** After a timeout the requester
deregisters nothing. The captured closure keeps polling `capturedSlotIdx`
forever. If `abandon()` won the CAS, the provider releases the slot back to
the free list; a *later* request claims the same index; when that request's
provider commits `Ready`, **two** pollers see it. The stale one decodes,
skips `complete` (its future is already finished), and calls
`pool.release(slot)` — the live requester's slot is pushed to the free list
while still in use, and may then be handed to a third request. Failure
surface: dropped/duplicated responses, double free-list push, eventually a
slot serving two requests at once.

**A-2 (use-after-free on the pool).** The stale poller holds
`capturedPool`. `clearProvider(ctx)` from any thread closes the ring; the
provider thread's poll fn hands `(ring, slab, pool)` to
`enqueuePendingRingFree`, and `drainPendingRingFrees()`
(`mt_broker_common.nim:375`) `deallocShared`s the pool after a **50 ms**
grace window sized for in-flight *senders*, not for an indefinitely
registered poller. Any surviving stale poller then dereferences freed
shared memory on every dispatch wake. Same class as the teardown UAF from
PR #13 / PR #38 — expect it to reproduce first on Windows refc and under
ASAN.

**A-3 (sync path leaks a slot).** `blockingSendAndAwait`
(`mt_request_broker.nim:1149`) does `discard pool[].abandon(slotIdx)` and
returns. When that CAS **fails** (provider already in `Writing`), the
provider commits `Ready` and nobody ever releases: the pool permanently
loses one slot per late response, until requests start failing with
`"response slot pool exhausted"`. No reaper exists on this path at all.

### A.2 Fix

Three changes, all inside `mt_request_broker.nim` + `mt_queue.nim`.

**A-F1 — packed state+generation (D1).** `ResponseSlotHeader` currently
carries `state: Atomic[uint8]`, `pad0: array[3, byte]` and a dead
`pad1: uint32` (`mt_queue.nim:437-453`). Replace `state`/`pad0`/`pad1` with

```nim
control: Atomic[uint64]   # (gen: uint32) shl 32 or (state: uint32)
```

Header size and alignment are unchanged (24 B: control(8) +
payloadSize(4) + overflowLen(4) + overflow(8)). `claim()` bumps `gen` and
stores `Empty` in one release store. All transitions become one CAS on the
pair:

| Helper | Signature | Semantics |
|---|---|---|
| `beginWrite` | `(idx, gen): bool` | CAS `(gen, Empty) → (gen, Writing)` |
| `abandonIfGen` | `(idx, gen): bool` | CAS `(gen, Empty) → (gen, Abandoned)` |
| `commitWrite` | `(idx, gen, size)` | store `(gen, Ready)`, release-ordered |
| `stateOf` | `(idx, gen): Opt[ResponseState]` | acquire load; `none` on gen mismatch |

A generation mismatch makes every operation a no-op instead of an action on
a reused slot. Call sites keep their current shape; only these four helpers
are rewritten.

**A-F2 — give-up protocol with explicit poller retirement.** Replace the
timeout tail with a shared state cell captured by both the poller closure
and the awaiting body (same thread, so a plain `ref` is fine — see R8):

```nim
type ReqWaitState = ref object
  gaveUp: bool        # requester stopped caring (timeout or cancel)
  reaping: bool       # provider was mid-write; we still owe the release
```

| Event | `abandonIfGen()` result | Poller action | Who releases the slot |
|---|---|---|---|
| Reply arrives first | — | decode, complete, release, **return 2** | requester (as today) |
| Give-up, CAS won | `true` | `gaveUp=true` → **return 2** immediately | provider (`beginWrite` fails → `release`) |
| Give-up, CAS lost | `false` | `reaping=true` → keep polling until `Ready`, then release, **return 2** | requester's reaper |

In the `reaping` window the slot is *not* in the free list, so it cannot be
reused — the reaper is bounded and cannot steal. In the `abandon-won` case
the poller is gone before the provider can release, so the reuse window
never opens. A-1 and A-2 both close.

**A-F3 — sync reaper.** `blockingSendAndAwait`: when `abandonIfGen()`
returns `false`, keep spinning (`sleep(1)`) on `Ready` for a bounded grace
window (proposal: `min(500 ms, timeout)`), then `release`. Log a chronicles
warn if the grace expires (that would mean the provider thread died
mid-write — the slot is then only recovered by `deinitResponseSlotPool`).

### A.3 Test plan (write these first — they fail today)

| Test | Asserts | Catches |
|---|---|---|
| `timeout then force slot reuse`: 1 request with a 50 ms timeout against a provider that sleeps 300 ms, then `responseSlots + 2` fast requests | every fast request gets its own correct payload; none returns `"response slot pool exhausted"` | A-1 |
| `late reply reaping`: provider replies just after the deadline, looped `responseSlots + 2` times | no exhaustion ⇒ every slot came back | A-3 (async + `blockingRequest` variant) |
| `timeout then clearProvider then teardown`, under `--mm:refc` + ASAN | clean exit, no ASAN report | A-2 |
| free-list accounting: test-only `freeSlotCount(pool)` before/after each of the above | equal to `capacity` | all |

Gates: `nimble test`, `nimble testApi`, `nimble testAllocRace` (Windows
cells), plus the ASAN/refc build per CLAUDE.md.

### A.4 Risk analysis

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R1 | Retiring the poller too eagerly (retire on `abandon==false`) turns A-1 into a permanent slot leak | med | high | the table in A-F2 is the whole contract; encode it in one helper used by both call sites, not duplicated inline |
| R2 | Double release: both the retired poller and the provider release | low | high (free-list corruption: same idx twice ⇒ two live requests share a slot) | single rule — *the side that wins the `Empty→X` CAS never releases*; add a debug-only `-d:brokerSlotAudit` assert that `release` sees `Ready`/`Abandoned` with a matching gen |
| R3 | `reaping` poller outlives its thread's dispatch loop (`stopBrokerDispatchHere` / `teardownBrokerThread` before `Ready`) | med | low | slot is reclaimed by `deinitResponseSlotPool` at pool teardown; document as accepted |
| R4 | Reaper still holds `capturedPool` while the provider thread frees it (A-2 residual, narrowed to the ≤ grace-window case) | low | high | reaper window is bounded by a provider that is *already mid-write*; if `drainPendingRingFrees`' 50 ms is judged too tight, gate the free on a per-pool `Atomic[int] inFlightWaiters` (incremented at `claim`, decremented at release/retire) and spin to zero before `deallocShared` |
| R5 | `gen` wraparound (2^32 claims of one slot index) | negligible | high if hit | note in the header comment; a single slot would need months of saturated reuse |
| R6 | ~~Torn `(state, gen)` read~~ | — | — | **closed by D1** — the pair is one atomic |
| R7 | Layout change breaks something that memcpy's the header | low | med | only `mt_queue.nim` touches `ResponseSlotHeader`; the struct never crosses a binary boundary (the pool lives inside the `.so`) |
| R8 | `ReqWaitState` `ref` captured by a closure under refc | low | med | both closures run on the requester thread only; never hand it to provider-side code |
| R9 | Per-poll cost | — | — | one 8-byte atomic load replaces a 1-byte one; the pollers seq now *shrinks* on timeout instead of growing |
| R10 | `mt_signal_broker` / `mt_event_broker` share the "poller that never returns 2" shape | med | med | audit item — no response slots there, so no reuse hazard, but the pending-free/UAF path (A-2) may rhyme |

### A.5 Sequencing

1. Tests from A.3 (red).
2. `mt_queue.nim`: packed `control` + the four helpers + `freeSlotCount` (test-only).
3. `mt_request_broker.nim`: A-F2 async retirement, A-F3 sync reaper.
4. Re-run gates + ASAN/refc; then `gitnexus_detect_changes`.

Blast radius: 2 files, ~120 lines of macro-generated code paths; no public
API change; no FFI surface change.

---

## Part B — explicit cancellation

### B.0 Why not the deadline variant

Rejected, for the reason raised in review: a deadline shipped in `ReqMsg`
has no defensible start point. `Moment.now()` *is* process-monotonic across
threads, so the clock itself is fine — the semantics are not. If the
deadline starts at enqueue, queue backlog is charged to the provider's
budget and a healthy provider is cancelled because the queue was deep; if
it starts at dispatch, the requester's timeout and the provider's budget
measure different intervals and a slow queue becomes invisible. Explicit
cancel has one unambiguous trigger: the caller asked.

### B.1 Surface (D2)

`request()` is `{.async: (raises: []).}`; chronos generates **no**
`CancelledError` branch for a `raises: []` proc
(`chronos/internal/asyncmacro.nim:113-137`), and manually created `raises:
[]` futures must own their cancel schedule (`raisesfutures.nim:102`). So
`someRequestFuture.cancel()` is not the API.

The handle is an **opaque value, not a pointer**:

```nim
type <T>RequestId* = distinct uint64      ## slotIdx shl 32 or gen; 0 = not cancellable

proc requestCancellable*(T, ctx, args…): (<T>RequestId, Future[Result[P, string]])
proc blockingRequest*(T, ctx, args…, idOut: ptr <T>RequestId = nil): Result[P, string]
proc cancel*(T, ctx: BrokerContext, id: <T>RequestId): bool
proc cancel*(T, id: <T>RequestId): bool    ## DefaultBrokerContext
```

Nothing is allocated, nothing is freed, no destructor or copy hooks, no
refc/ORC divergence, and no lifetime obligation on the caller. A stale id
(slot already reused) fails the gen check inside one CAS and is a no-op
returning `false`.

**Where the id comes from.** `sendAndAwait` is already synchronous up to
`fireBrokerSignal` (`mt_request_broker.nim:936-1005`); only the poller
registration and the `withTimeout` are async. Split it:

```
sendPrologue(...)  : (RequestId, ok/err)   # sync: claim slot, marshal, enqueue, fire
awaitReply(...)    : Future[Result[…]]     # async: register poller, wait
```

`requestCancellable` is then a **non-async** proc that runs the prologue and
returns the id together with the future produced by the async tail. The id
is therefore fully determined *before the caller can possibly call
`cancel`* — which removes the cancel-races-arming window entirely, and with
it the need for any pending-cancel set. Prologue failures (slot pool
exhausted, ring full, marshal failure) return id `0` plus an
already-completed error future.

The existing `request()` / `blockingRequest()` overloads stay untouched and
non-cancellable; `blockingRequest` gains an optional `idOut: ptr
<T>RequestId` written during the prologue. That pointer must only stay
valid for the duration of the call — trivially true for a *blocking* call,
since the caller's frame cannot go away while it is blocked. This is the
one place a caller-supplied location is used, and it is the safe one.

### B.2 Mechanism

Cancellation reuses the state machine that already exists — `Abandoned` is
exactly "requester gave up" — so no new slot state is needed. During
provider execution the slot is still `Empty` (`Writing` is only entered in
`sendReply`), which is what makes an in-flight cancel expressible at all.

1. **Publish cancel (lock-covered).** `cancel(T, ctx, id)` takes the
   existing per-type global bucket lock, finds the bucket for `ctx`, and
   performs `pool.abandonIfGen(slotIdx, gen)` **while still holding the
   lock**; it also bumps the pool's `cancelEpoch` and copies out the two
   signal pointers. Signals are fired after unlocking (firing a signal
   whose owner thread has exited is a documented no-op,
   `mt_broker_common.nim:261`).

   *Why the lock makes this UAF-free:* `clearProvider` removes the bucket
   under the same lock **before** it closes the ring
   (`mt_request_broker.nim:1571-1591`), and the pool is only handed to
   `enqueuePendingRingFree` by the provider poll fn *after* it observes the
   closed ring. So "bucket found under the lock" implies "pool not yet
   queued for free". If the bucket is gone, `cancel` returns `false`
   without touching any pool memory.

2. **Pre-start drop (D3).** In the provider poll fn, between `tryDequeue`
   and `asyncSpawn` (`mt_request_broker.nim:735-745`): if the slot is
   `Abandoned` with a matching gen, release slot + slab cell and skip the
   dispatch. A Vyukov MPSC ring cannot remove an element, so the message is
   *tombstoned* and dropped at the consumer — ~8 lines, no ring surgery.
   This also makes today's timeouts stop executing queued work.

3. **In-flight cancel.** `handleMsg` currently does `catch: await
   handler(args)`. Split it: `let fut = handler(args)`; register
   `(slotIdx, gen, fut)` in a provider-thread `seq`; `catch: await fut`;
   unregister via `defer`. Add `cancelEpoch: Atomic[uint32]` to
   `ResponseSlotPool`, bumped by every abandon. The poll fn compares the
   epoch against its last-seen value (one relaxed load in the common case)
   and, only on change, scans the in-flight seq and `cancelSoon()`s futures
   whose slot is `Abandoned` with a matching gen. The provider proc type is
   plain `{.async.}` (`mt_request_broker.nim:269`) ⇒ raises
   `CatchableError` ⇒ chronos emits the `CancelledError` branch ⇒ the
   provider future is genuinely cancellable at its await points.

4. **Reply path unchanged.** `handleMsg` still calls `sendReply` on the
   cancelled path; `beginWrite` fails and the provider releases the slot —
   which is what keeps the "abandoner never releases" invariant intact. Map
   a `CancelledError` out of `catch` to a dedicated err string rather than
   `"provider threw exception: …"`.

5. **Requester wake-up.** The requester's poller (Part A's version) gains
   one branch: state `Abandoned` with matching gen ⇒ complete the future
   with `err("RequestBroker(<T>): request cancelled")` and **retire without
   releasing**. Because `cancel()` may run on another thread it must never
   touch the future — it only publishes state and fires the signal; the
   requester's own dispatch loop resolves it. The blocking spin gets the
   same branch.

6. **Timeout re-expressed.** The existing timeout path becomes
   `cancel`-on-self: same `abandonIfGen` + the same retirement table. One
   code path, two triggers.

### B.3 Scope limits (phase 1)

| Case | Phase 1 behaviour |
|---|---|
| Cross-thread `requestCancellable` | fully cancellable (pre-start + in-flight) |
| Cross-thread `blockingRequest` + `idOut` | cancellable by *another* thread (the caller is spinning) |
| Same-thread `request` | no slot, no queue (`mt_request_broker.nim:1185`) — id is `0`, `cancel` returns `false`; documented. A later phase can keep the future in a per-thread id registry |
| `SignalBroker` / `EventBroker` | out of scope (no reply path) |
| FFI `_call` / `_callAsync` | out of scope; a `<lib>_cancelCall(handle)` becomes possible once B lands, since the CBOR adapters go through `T.request(ctx)` (`api_request_broker_cbor.nim:263`) |

### B.4 Risk analysis

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| S1 | Cancel lands on a reused slot (ABA) | **high without Part A** | high — cancels an unrelated request | gen is half the id and is checked inside the single CAS (D1); Part A is a hard prerequisite |
| S2 | Handle lifetime / UAF | — | — | **closed by D2** — the id is a `uint64` value, not a pointer. The single `ptr` (`idOut`) is only dereferenced inside a blocking call, where the caller's frame is alive by construction |
| S3 | Cancel racing arming | — | — | **closed by D2** — the sync prologue completes arming before the id exists, so a caller cannot cancel earlier than arm |
| S4 | `CancelledError` escaping into `handleMsg`'s `raises: []` frame | med | high (crash) | `handleMsg` keeps `catch:` around the await, so it is converted, never propagated; unit test with a provider awaiting `sleepAsync` |
| S5 | Provider ignores cancellation (no await points, or swallows `CancelledError`) | med | low | documented: cancellation is cooperative; the requester resolves regardless via the `Abandoned` branch |
| S6 | In-flight scan cost grows with concurrency | low | low | epoch gate makes the common path one relaxed load; the scan is O(in-flight) only after a real cancel |
| S7 | `ReqMsg` grows | — | — | not needed — the slot index *is* the identity; `ReqMsg` and therefore `mt_codec` output and payload sizing stay untouched |
| S8 | Provider-thread in-flight registry holds a `Future` ref under refc | med | med | threadvar `seq` on the provider thread only; entries removed by `defer` in the frame that created them |
| S9 | Behaviour change: timeouts/cancels now drop queued-but-unstarted work (D3) | certain | low-med | intended, but a semantic change — call it out in `doc/MultiThread_RequestBroker.md` and the changelog |
| S10 | Cancel arriving after `clearProvider`, pool already freed | low | high | the lock-covered CAS in B.2 step 1 — bucket present under the lock ⇒ pool not yet queued for free; bucket absent ⇒ `false`, no dereference |
| S11 | `requestCancellable` prologue runs outside an async frame | low | med | it needs `ensureBrokerDispatchStarted()` / `getOrInitBrokerSignal()`, both callable from a chronos-loop thread; document that the caller must be on such a thread (already true for `request`) |

### B.5 Sequencing

| Phase | Content | Verify |
|---|---|---|
| B-0 | Part A complete and green | A.3 suite |
| B-1 | `RequestId`, `abandonIfGen`, prologue/tail split, `requestCancellable`, `blockingRequest(idOut)`; cancel resolves the requester only | cancel before the provider replies ⇒ `err(cancelled)`, slot returns to the pool |
| B-2 | Pre-start drop in the poll fn (D3) | cancel a request queued behind a slow provider ⇒ provider never invoked (counter assertion) |
| B-3 | In-flight registry + `cancelEpoch` + `cancelSoon` | provider awaiting `sleepAsync(5 s)` is cancelled within ms; its `CancelledError` handler runs |
| B-4 | Timeout re-expressed on the same primitive; docs (`USAGEGUIDE.md`, `doc/MultiThread_RequestBroker.md`), changelog for D3 | full gates + ASAN/refc |

Blast radius: `mt_queue.nim`, `mt_request_broker.nim`, plus docs. Public API
additive only. FFI surface untouched in this plan.
