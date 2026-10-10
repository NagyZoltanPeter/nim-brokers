# MT owner-only clear / drop — plan

Status: **implemented, uncommitted** (2026-10-10) — all steps except marking H2/H3 resolved in `BROKER_SCOPE_PLAN.md` (lives on `feat-broker-scope`). Branch `mt-owner-only-clear`
(from `master` 5d711f4).

## Goal

A `RequestBroker(mt)` provider — and a `SignalBroker(mt)` handler — may only
be cleared, dropped or replaced by the thread that installed it (its *owner*:
the `(threadId, threadGen)` recorded in the shared bucket). This is already the
documented contract (`doc/MultiThread_RequestBroker.md` §6 "`clearProvider`
must be called from the provider thread", `USAGEGUIDE.md` SignalBroker(mt)
notes); it is **not enforced** today. The `(API)` lane rides the MT lane and
inherits the change.

## Current behaviour (master)

| Path | Non-owner thread today | Where |
|---|---|---|
| `setProvider` | rejected — "provider already set from another thread" | `mt_request_broker.nim` `setupBucket<T>` |
| `replaceProvider` | **already rejected** — the non-owner has no threadvar (tv) entry, falls into `setupBucket` → same error → rolls back the tv append | `replaceProvider` (both slots) |
| `clearProvider` | **succeeds** — bucket looked up by ctx only, no owner check; tv cleanup skipped (`if isProviderThread`) | `clearBody` |
| `dropSignalHandler` | **succeeds** — same shape; tv cleanup skipped (`if isOwner`) | `mt_signal_broker.nim` `dropImpl` |
| `withMockProvider` / `withMockSignalHandler` | install fails, error **discarded** → body runs against the *real* provider; `finally` then clears the owner's provider | generated templates |
| Provider thread exits without clearing | bucket stays forever: ctx blocked ("already set"), requests hang to their timeout. The only recovery was a foreign `clearProvider` (`doc/MultiThread_RequestBroker.md` "clearProvider on a dead provider thread") | `teardownBrokerThread` removes no buckets |

### Why a foreign clear is harmful (traced on master)

Thread A owns the provider; R1 is executing, R2..Rn are queued in A's ring;
thread B calls `clearProvider(ctx)`:

1. B removes the bucket and `markProviderGone()` flips every `Empty` slot
   (R1..Rn — the provider writes only after it finishes) to `ProviderGone`,
   wakes the requesters, **skips A's tv cleanup**, closes the ring.
2. Requesters resolve `err("provider was cleared …")` and release their slots.
3. On A: R1 runs to completion (the cancel scan only `cancelSoon`s
   `Abandoned` slots), its reply is dropped (`beginWrite` → `Stale`). The
   closed ring is still drained; `isAbandoned` matches only `Abandoned`, and
   `handleMsg` resolves the provider from A's **stale** tv entry — so **R2..Rn
   execute on the dead provider** after their callers were told they failed.
   With an owner clear, tv cleanup runs first and the drained R2..Rn find a
   nil provider (not executed).
4. A's stale tv entry also corrupts introspection / mocks (H2/H3 in
   `BROKER_SCOPE_PLAN.md`, feat-broker-scope branch).

Memory safety is preserved (generation-checked slots; ring/slab/pool freed
only on A at teardown) — the problem is ownership and side-effect semantics.

## Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | A foreign `clearProvider` / `dropSignalHandler` is a **no-op + chronicles `error` log** | Keeps the uniform sync `void` shape of `clearProvider` across ST/MT/API lanes and every call site; a Defect would kill the host process when hit on an FFI processing thread |
| D2 | **Auto-clear a thread's owned buckets in `teardownBrokerThread`** | Enforcement removes the only dead-owner recovery path; without this a dead owner blocks its ctx permanently. Bonus: outstanding requests fail fast instead of timing out |
| D3 | **SignalBroker(mt) included** | Identical defect (H3); its docs already state owner-only |
| D4 | **New PR from `master`**; drop the `purgeStaleTv` commit (e9caa32) from PR #63, which keeps only the chronos fixes | With enforcement no stale tv entry can arise, so the purge would be merged then deleted |
| D5 | Mock helpers on a non-owner **`doAssert`** the install succeeded | Test helper — misuse should fail hard, not silently exercise the real provider |

Out of scope: `EventBroker(mt)` `dropListener` / `dropAllListeners` from a
non-owner (listeners are per-thread buckets — separate analysis). R1 (an
already-running provider) is still not cancelled by a clear — unchanged.

## Steps

1. **`clearProvider` owner check** — `mt_request_broker.nim` `clearBody`:
   under the global lock remove the bucket only when its
   `(threadId, threadGen)` matches the caller; otherwise leave it, release the
   lock, log `error` (D1), return. tv cleanup becomes unconditional (only the
   owner reaches it); drop `isProviderThread`. Clearing an absent ctx stays an
   idempotent no-op.
2. **`dropSignalHandler` owner check** — `mt_signal_broker.nim` `dropImpl`:
   same; decrement the handler-present counter only on an actual removal.
3. **Auto-clear at thread exit (D2)** — `setupBucket<T>` (request + signal)
   registers a per-thread owned-bucket cleanup closure alongside
   `registerBrokerPoller` (new per-thread registry in `mt_broker_common.nim`).
   `teardownBrokerThread` runs those closures **first** (before
   `stopBrokerDispatchHere` / `drainPendingRingFrees`). Each does the owner
   clear: remove bucket, `markProviderGone` + wake requesters, close the ring,
   hand (ring, slab, pool) to the pending-free registry directly (the poll fn
   may not run again). A normal owner `clearProvider` unregisters its closure
   so teardown does not double-clear. Under refc this runs before
   `deallocOsPages` (existing hook ordering).
4. **Mock helpers (D5)** — `withMockProvider` (both slots) and
   `withMockSignalHandler`: `doAssert` that the mock install returned `ok`.
5. **No `purgeStaleTv`** (D4) — not ported to this branch.
6. **`BrokerImplement.close()`** (`broker_implement.nim`) — document that it
   must run on the creating thread; a foreign call hits D1.
7. **Tests** — `test/test_mt_owner_only_clear.nim`, wired into `mtTests`
   (`brokers.nimble`). For RequestBroker(mt) and SignalBroker(mt):
   - foreign clear / drop refused: provider still serves, `isProvided` true,
     owner `getCurrentProvider` / `getCurrentSignalHandler` unchanged;
   - foreign `replaceProvider` returns `err` (pins existing behaviour);
   - foreign `withMockProvider` → `AssertionDefect` (`expect`);
   - owner clear while busy (R1 running, R2..R4 queued): provider call count
     shows R2..R4 never executed;
   - owner thread exits without clearing → another thread can `setProvider`
     the same ctx; an outstanding cross-thread request resolves with
     "provider was cleared" well before its timeout.
8. **Docs** — `doc/MultiThread_RequestBroker.md` §6 (must → enforced) and the
   dead-thread paragraph (→ auto-clear); `USAGEGUIDE.md` SignalBroker(mt)
   notes; `AGENTS.md` RequestBroker / SignalBroker specifics. Mark H2/H3
   resolved in `BROKER_SCOPE_PLAN.md` (lives on `feat-broker-scope`). No
   CHANGELOG edit (release process owns it).
9. **Verify** — `nimble test`, `nimble testApi`, `nimble testAllocRace`, ASAN
   (clang) builds of the MT request + signal tests under refc (step 3 changes
   lifetimes), `nimble runFfiExampleCpp` / `runFfiExamplePy` (teardown path);
   against chronos 4.2.2 (pinned via a temporary gitignored `nimble.paths`) and
   chronos master. Windows: rely on the Windows CI cells.

## Memory model / platforms

| Aspect | refc | ORC | Note |
|---|---|---|---|
| tv cleanup on clear | owner heap only | owner heap only | a foreign thread never touches another thread's GC heap (already true; now the only path) |
| auto-clear at teardown | before `deallocOsPages` | same hook order | runs inside `teardownBrokerThread`, while the thread heap is alive |
| Windows | — | — | cleanup must precede the `RegisterWaitForSingleObject` dismantling in `teardownBrokerThread`; validated only by Windows CI |
