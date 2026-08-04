# Cross-check: how nim-ffi's design avoids the nim-brokers CBOR-FFI findings

- **Date:** 2026-07-30
- **Compared:** nim-brokers `2b0732e` (master) CBOR FFI lane ⟷ `logos-messaging/nim-ffi` master `aad9374`
  (0.3.0 line, "{.ffi.} shape router, {.ffiExport.}, context recycling" #142)
- **Scope:** nim-ffi is an FFI-layer library only, so this compares only the **nim-brokers CBOR FFI
  lane** (`api_library.nim`, `api_cbor_*`, the `*_cbor_*` codegen). The `(mt)` broker internals
  (H3, M9, S5–S9) are outside nim-ffi's remit — but where a *design pattern* transfers, it is
  called out.
- Companion to [`SECURITY_AUDIT_2026-07.md`](SECURITY_AUDIT_2026-07.md) and
  [`SECURITY_FIX_PLAN.md`](SECURITY_FIX_PLAN.md).

nim-ffi is ~9.1 kLOC total (~1.5 kLOC of core runtime) against nim-brokers' ~25 kLOC of broker code
with a much larger FFI surface. Some of the divergence is simply scope. But several differences are
**deliberate, documented safety decisions** that structurally remove classes of defect the audit
found — and in two cases nim-ffi's source comments name the exact hazard.

---

## 1. The decisive difference: no blocking sync call, and nothing is ever abandoned

**nim-brokers (H1, H2).** `_call` parks the foreign thread in `waitSlot` on a per-slot
`Cond`/`Lock` with **no timeout** (`api_cbor_courier.nim:468-479`), while `_shutdown` frees those
very primitives after a best-effort 5 s drain (`api_library.nim:1748-1800`) → use-after-free.

**nim-ffi.** There is **no blocking wait anywhere on the ABI**. Every generated entry point takes
`(callback, userData)` and returns an `int` status immediately after enqueueing
(`ffi_thread.nim:5-32`, entry codegen `ffi_macro.nim:982-994`). The result is delivered later by
invoking `FFICallBack` exactly once. Consequences:

- **H1 cannot occur**: no caller is ever blocked on library-owned synchronization, so there is no
  "free under a blocked waiter" window. There is no response-slot pool at all.
- **H2 cannot occur**: there is nothing to time out on the callee side.
- The "sync" ergonomics foreign users expect are provided **in the wrapper's own language**
  (`ffi_call_sync(timeout, …)` in the Rust codegen, `codegen/rust.nim:607,767`) — the foreign side
  stops *waiting*, which never asks Nim to abandon state.

**And nim-ffi deliberately refuses to time out handlers at all**
(`ffi_context.nim:84-86`, `ffi_thread.nim:34-59`):

```nim
proc awaitWithStaleWarnings(...) =
  ## Pings RET_STALE_WARN every `interval` while the handler runs, then returns
  ## its real result. Never cancels the handler: a hard-cancel mid-call could
  ## leave the underlying library partially applied.
  ...
  # `race` doesn't cancel the loser, so the handler keeps running.
```

A slow handler produces repeated **non-terminal** `RET_STALE_WARN` callbacks carrying elapsed ms;
the terminal `RET_OK`/`RET_ERR` is still owed and still fires. `request.responded` de-dupes
(`ffi_thread_request.nim:33-34, 180-186`).

**This eliminates the entire abandon-then-reuse race class** — which is precisely what
nim-brokers H3 (leaked poller `release()`s a recycled slot) and S5 (slot stuck `Ready` after a
failed `abandon`) are. There is no shared slot to abandon: the request object *is* its own queue
node, owns its payload, and is freed exactly once at `handleRes` (`ffi_thread_request.nim:230-234`).
Single owner, single free point, no state machine to race.

> **Transferable lesson (H3/S5):** the bug class comes from *timeout = abandon a shared slot the
> peer may still write*. "Report slowness, never abandon ownership" removes it by construction.

---

## 2. Teardown on timeout: leak instead of free

This is the direct answer to **H1**, and nim-ffi states it as an invariant in three places:

| nim-ffi site | Policy |
|---|---|
| `ffi_context.nim:195-202` (`waitExitOrErr`) | `err("did not exit in time: … (leaking ctx to avoid hang)")` |
| `ffi_context.nim:256-257` (`stopAndJoinThreads`) | "On timeout, returns err and **skips remaining joins** (leaves threads live); caller cleans up" |
| `ffi_context_pool.nim:71-77, 123-126` | "On thread-exit timeout **the slot is leaked; closing live-thread resources is unsafe**" / "Threads are still live: **leak the slot rather than free resources under them**" |

nim-brokers does the opposite on the same dilemma: the 5 s drain expires and it proceeds to join and
`freeCborCourier` unconditionally. **A bounded leak is strictly safer than an unbounded UAF** — and
this is exactly the resolution `SECURITY_FIX_PLAN.md` PR 1 proposes, already proven in a sibling
codebase.

nim-ffi also drains in **two rounds** before giving up (`ffi_thread.nim:129-147`): wait for in-flight
handlers, then `cancelSoon` them, then wait again — and only then frees the lib.

---

## 3. Allocator choice: libc `malloc`/`free`, never `allocShared`

nim-brokers uses `allocShared0`/`deallocShared` throughout the FFI lane. nim-ffi bans it, and says
why — twice, in file headers:

```nim
## Cross-thread allocation helpers backed by libc `malloc`/`free`.
## Avoids Nim `allocShared` whose TLS-owned MemRegion segfaults when freed from a
## thread other than the one that allocated (and may have since exited); libc is process-global.
```
— `alloc.nim:1-3`

```nim
## Request blob passed main→FFI thread. Uses libc malloc/free (not Nim
## allocShared) so a producer thread exiting before the FFI thread frees can't
## dangle into reclaimed per-thread ORC TLS.
```
— `ffi_thread_request.nim:1-3`

Every cross-thread buffer in nim-ffi (request envelopes, payloads, event slots, name slabs,
callback boxes) is `c_malloc`/`c_free`. This is a **structural** mitigation for the family of
cross-thread-free hazards that nim-brokers documents at length in `LIMITATION.md` §2.2 and works
around with the `BrokerSignalShared` wrapper + `teardownBrokerThread` contract (audit **S13** — a
footgun foreign callers must remember, unenforceable at the ABI).

GC-heap objects that *must* be thread-affine are freed on their owning thread explicitly:
`ffi_thread.nim:179-183` — `defer: ctx[].handles.releaseAll()` with the comment "Free handle refs on
the thread that allocated them (refc heap is thread-local)."

---

## 4. Buffer ownership: copy-in at the boundary, caller keeps its buffer, typed frees

**nim-brokers (M7, M5).** `reqBuf` ownership **transfers to the library** on every `_call` path;
`_freeBuffer(void*)` will free *any* pointer with only a nil check (`api_library.nim:831-837`) —
enabling double-free, and freeing the static `_version()` string. The payload `copyMem` happens
later, on the processing thread, sized by the caller's `reqLen` (`:1391-1393`).

**nim-ffi.** Ownership never transfers:
- The generated C wrapper allocates `req_buf`, calls the entry point, and **frees its own buffer
  immediately after the call returns** (`codegen/c.nim:582-583`).
- That is sound because the Nim entry **copies the payload synchronously** into a fresh `c_malloc`
  buffer owned by the request (`ffi_thread_request.nim:73-78, 91-102`) before returning.
- Symmetric rule: *each side frees what it allocated.* No transfer, no ambiguity, no reflexive-free
  footgun.
- Library-produced buffers are freed by **typed, per-type functions** — `nimffi_free_str`,
  `nimffi_free_bytes`, `<lib>_free_<Type>(<Type>* v)` (`codegen/c.nim:73-92, 129, 284`), with
  `owns` marking types the caller must free (`:297`). A typed `<lib>_free_MyStruct(MyStruct*)`
  cannot be handed the version string; a generic `_freeBuffer(void*)` can.

Also worth copying: nim-ffi never hands a callback a nil pointer, even at length 0 —
`emptyListenerPayload` is a non-nil zero-length stand-in because "nil would be UB for consumers
doing memcpy even at len 0" (`ffi_events.nim:115-118, 253-264`), and `notifyListeners` clamps with
`max(dataLen, 0)`. That is precisely the guard nim-brokers' Go path lacks (**S12**).

---

## 5. Handle/context validation: whitelist, not blind cast

**nim-brokers (M6, S4).** `_subscribe`/`_unsubscribe` dereference a nil registry if called before
`_createContext` (`api_library.nim:1134-1166` → `api_cbor_subs_registry.nim:217`); `ctx` is a small
guessable integer routed by its low 16 bits with no liveness check (`:1865-1875`).

**nim-ffi.** Two layers, both fail-closed:

```nim
proc isValidCtx*[T](pool: var FFIContextPool[T], ctx: pointer): bool =
  ## Rejects nil / dangling pointers at the API boundary.
  if ctx.isNil(): return false
  for i in 0 ..< MaxFFIContexts:
    if cast[pointer](pool.contexts[i].addr) == ctx:
      return pool.contexts[i].addr.isInUse()
  false
```
— `ffi_context_pool.nim:135-142`

A ctx must match the address of a slot in the **fixed pool array** *and* be currently claimed. A
forged, stale, or released handle is rejected. This guard is emitted into **every** generated entry
point, together with a callback nil-check, by a single shared codegen helper
(`ffi_macro.nim:958-966`, used at `:702, :963`):

```nim
if callback.isNil: return RET_MISSING_CALLBACK
if not `poolIdent`.isValidCtx(cast[pointer](ctx)):
  ... callback(RET_ERR, "ctx is not a valid FFI context", ...); return RET_ERR
```

Object handles get the same treatment with an added **type check**: `lookup(handle, typeName)`
returns `err` if the id is absent *or registered under a different type*
(`ffi_handles.nim:34-46`) — no blind cast to the expected type.

---

## 6. Lock strategy: sharded mutexes on purpose, not lock-free

nim-brokers' FFI lane rides the MT machinery: Vyukov MPSC rings, ABA-tagged sharded Treiber free
lists, hand-rolled atomics. The audit confirmed those primitives are *correct*, but the surrounding
glue produced **M8** (non-atomic check-then-set lazy init) and **M9** (`moRelaxed` fast-path load
missing the acquire edge — five sites).

nim-ffi chooses plain mutexes with short critical sections and spreads contention by **sharding**:

- `ffi_request_queue.nim:1-3` — "Sharded, mutex-guarded MPSC ingress … N intrusive FIFOs (one per
  producer) spread lock contention; the request is its own node so enqueue never touches a Nim GC
  heap. Unbounded — submit never blocks." 16 queues, each `Lock`-guarded, padded 192 B against false
  sharing, producer→queue assignment round-robined via one atomic counter.
- `ffi_events.nim:128` — `EventQueue` is an "SPSC ring; **plain lock** since ops are short and
  uncontended."
- Snapshot-then-fan-out with the lock held only across the copy (`snapshotListeners`, `:94-102`) —
  same proven pattern nim-brokers uses for `emit`.

**A whole bug class disappears:** with no hand-rolled memory ordering on the hot path, M9-style
acquire/release mistakes are not expressible. Where nim-ffi *does* use atomics it is for coarse
lifecycle state, and it uses **CAS state machines** rather than bare flags —
`CtxLifecycle` `Active → RecyclePending → Recycling → Active` (`ffi_context.nim:18-26, 228-238`;
`ffi_thread.nim:228-230`), and `StaticCtxState` with a spin-on-`Creating` loop
(`ffi_context_pool.nim:89-112`). A double-recycle is rejected by the CAS
(`err("requestRecycle: context is not Active (already recycling)")`) instead of racing.

---

## 7. Bounded resources with real backpressure, and no abort-on-exhaustion

| Concern | nim-brokers | nim-ffi |
|---|---|---|
| Subscriptions | **S3**: unbounded; `_subscribe` never validates `ctx`, each call `allocShared0`s a node → OOM | Listener registry is per-validated-ctx and cleared on recycle (`clearListeners`) |
| Event backlog | Courier ring + 50 ms grace free window (**S6**) | `EventQueueCapacity = 1024` bounded ring; on full sets a **sticky `eventQueueStuck`** flag (`ffi_events.nim:285-302`) that the **request entry point reads to reject new work** (`ffi_thread.nim:8-10`) — backpressure that reaches the ABI |
| Event payload | per-emit alloc | pre-allocated per-slot slabs (`MaxEventPayloadBytes = 512`, `MaxEventNameBytes = 64`) with a one-off `c_malloc` fallback freed on commit (`copyIntoSlot`, `:175-189`) |
| Context ids | **S2**: monotonic, never recycled, `doAssert` → **`Defect` aborts the host** after 65 534 cycles | Fixed pool of 32, **recycled**; exhaustion returns `err("FFI context pool exhausted (max 32 contexts)")` (`ffi_context_pool.nim:52`). Also bounds `ThreadSignalPtr` fds by construction |

nim-ffi also **pins the event slot during read**: `peekEvent` returns the head without advancing so
"the producer can't reuse it mid-read; pair each non-none peek with a `commitDequeue`"
(`ffi_events.nim:231-247`) — an explicit ownership handoff rather than a timed grace window.

And on recycle it **fails queued requests instead of running them** (`ffi_thread.nim:115-127`):

> "A request that a destroyed context left behind still carries that host's `userData`, which the
> host has freed; running it would answer a dead callback, and running it after the slot is reused
> would run it against the library of the next owner."

That is the **M2** hazard (callback fires against freed host state), closed by policy. The
consumer side also re-checks lifecycle after the CAS to close the submit/recycle TOCTOU window
(`ffi_thread.nim:233-236`).

Two more defensive touches with no nim-brokers equivalent:
- **Reentrancy guard**: `onFFIThread` threadvar → a handler re-dispatching onto its own FFI thread
  is rejected, because it would deadlock (`ffi_thread.nim:12-17`).
- **Liveness observability**: `ffiHeartbeat` advanced per dispatch and polled by the event thread,
  so a wedged FFI thread is detectable instead of silently hanging (`ffi_thread.nim:165-167, 214`).
  Deadlock-awareness is explicit: `signalStop` skips `onNotResponding` because "it takes reg.lock a
  stuck listener may hold (deadlock risk)" (`ffi_context.nim:205`).

---

## 8. Finding-by-finding verdict (CBOR FFI lane)

| # | nim-brokers finding | nim-ffi approach | Verdict |
|---|---|---|---|
| **H1** | `_shutdown` UAF past 5 s drain | No blocking waiter; leak-not-free on timeout | **Prevented** (structural + policy) |
| **H2** | sync `_call` no timeout | No sync ABI path at all | **Prevented** |
| **H3** | timeout leaks poller → slot double-release | *(mt lane)* but: never abandon, stale-warn instead | **Class removed** by design |
| **M1** | callback throw/panic crosses C ABI | Rust event trampoline calls `(h.f)(&payload)` with **no `catch_unwind`**; no `noexcept`/`recover` anywhere in codegen | **Shared gap** — nim-ffi is *aware* (`rust.nim:446` "ensure the callback doesn't panic") but enforces it only by comment |
| **M2** | in-flight callback vs shutdown UAF | Queued requests rejected on recycle; slot pinned during read; typed handle registry | **Prevented** |
| **M4** | `maxPayloadBytes` doesn't bound decode | No misleading knob; event side genuinely bounded | **Avoided** (no false assurance); request side uncapped |
| **M5** | `reqLen` trusted as `copyMem` size | Copies with caller's `dataLen` too (`copySharedPayload`) — no cap either | **Shared gap** (inherent to `(ptr,len)`); mitigated only by wrapper-generated buffers |
| **M6** | `_subscribe` nil-deref pre-init | `isValidCtx` + callback nil-check at *every* entry, from one shared helper | **Prevented** |
| **M7** | `_freeBuffer(void*)` frees anything | Caller keeps ownership; typed per-type frees; `owns` annotation | **Prevented** |
| **M8** | discovery lazy-init data race | CAS state machines for all lifecycle state | **Prevented** |
| **M9** | `moRelaxed` init fast-path | Mutexes on hot paths; no hand-rolled ordering to get wrong | **Class removed** |
| **S1** | CBOR depth/count delegated to floating dep | Same `cbor_serialization`, but **`== 0.3.0` exact pin** + same try/except→Result | **Shared gap**, better pinned |
| **S2** | ctx exhaustion `doAssert` aborts host | Pool recycling; `err` on exhaustion | **Prevented** |
| **S3** | unbounded subs growth | Bounded queue + sticky stuck flag + ABI reject | **Prevented** |
| **S4** | guessable unvalidated ctx ints | Pool-address whitelist + `isInUse` + typed handle lookup | **Prevented** |
| **S10** | `strlen` on caller cstring | Same `cstring` intake contract | **Shared gap** |
| **S12** | Go `C.GoBytes` unguarded length | Trampolines guard `ud.is_null() ‖ msg.is_null() ‖ len == 0` before `from_raw_parts`; non-nil empty sentinel | **Prevented** |
| **B1** | no lockfile, floating `>=` deps | **`nimble.lock` committed** (vcsRevision + sha1 per package); `cbor_serialization == 0.3.0`; `versions.env` pins Nim/nimble | **Prevented** |
| **B2** | Actions pinned by mutable refs | `actions/checkout@v4`, `jiro4989/setup-nim-action@v2`, `arnetheduck/nph-action@v1` — also mutable | **Shared gap** |

**Score:** of the 19 FFI-lane items, nim-ffi structurally prevents or removes **13**, shares **5**
gaps, and avoids 1 by not offering the misleading knob.

---

## 9. Honest counterweight — what nim-ffi does *not* solve, and what doesn't transfer

**Shared gaps (do not assume nim-ffi is a template here):**
- **M1 panic/exception isolation is unsolved in nim-ffi too.** No `catch_unwind`, `noexcept`, or
  `recover` in any of its codegen. nim-brokers is actually *ahead* here in two places (its C++
  event path and both Python trampolines already guard). Fix this from first principles, not by
  copying.
- **M5/S10 raw `(ptr,len)` and `cstring` trust** are inherent to a C ABI; nim-ffi copies with the
  caller's length just the same, and has no size cap at all.
- **S1** — both delegate CBOR structural safety to `cbor_serialization`. nim-ffi's exact pin makes
  the behaviour auditable and reproducible; it does not add depth/count limits.
- **B2** — both leave third-party Actions on mutable refs.

**Design differences that are requirements, not defects:**
- nim-brokers *offers a synchronous `_call`* as a first-class ABI feature; nim-ffi does not. Much of
  nim-ffi's safety margin comes from **not having that feature**. Removing sync `_call` outright is
  an ABI break — hence the fix plan's bounded-wait + keep-alive-refcount approach, which is the
  correct compromise for a lane that must keep it.
- nim-brokers must serve the `(mt)` broker lane (fan-out `emit`, multi-provider, per-context
  buckets) with its own performance envelope; the lock-free rings exist for that. The audit found
  those primitives *correct*. The lesson is not "delete them" but "prefer mutex/CAS for
  **lifecycle** glue," which is where M8/M9 actually live.
- nim-ffi's fixed pool of 32 contexts is a real functional ceiling; nim-brokers' unbounded ids trade
  that ceiling for the S2 abort. A bounded, recyclable pool that *errors* is the better trade.

---

## 10. Adoption decision (maintainer, 2026-07-30)

**Guiding rule: nim-brokers is not nim-ffi.** Both are legitimate designs that overlap in places.
Only adopt what slots into nim-brokers' existing architecture — **nothing requiring a design or
deep structural change.** The list below is split accordingly.

### ✅ ADOPT — local, no architectural change

| # | Adoption | Fixes | PR |
|---|---|---|---|
| 1 | **Leak-instead-of-free on teardown timeout**: if the drain does not reach quiescence, return `err` and do **not** `freeCborCourier`. Add the two-round drain (wait → cancel → wait). | H1 | 1 |
| 2 | **Bounded `waitSlot` + courier keep-alive refcount** — keeps sync `_call` while closing the free-under-waiter window. | H1, H2 | 1 |
| 3 | **One shared entry-point guard helper** emitting ctx-validity + callback nil checks, so no entry point can forget them. | M6, S4 | 5 |
| 4 | **Buffer-provenance tagging** on `_allocBuffer`/`_freeBuffer` (guard header), so `_freeBuffer` rejects foreign/static/already-freed pointers. | M7, M5 | 5 |
| 5 | **Never hand a callback a nil pointer at length 0** — non-nil empty sentinel + `max(len,0)` clamp; add the Go `outLen > 0` guard. | S12 | 7 |
| 6 | **CAS state machines for lifecycle glue** instead of non-atomic check-then-set; `moAcquire` on init fast paths. | M8, M9 | 6 |
| 7 | **Bounded queue + backpressure that reaches the ABI**, and **validate `ctx` in `_subscribe`** with a cap. | S3 | 7 |
| 8 | **Error, don't abort, on context exhaustion** — return an ABI status instead of `doAssert`. | S2 | 6 |
| 9 | **Commit `nimble.lock`; pin `cbor_serialization` exactly.** Direct precedent, zero design impact. | B1, S1 | 8 |

### ❌ NOT ADOPTED — would change nim-brokers' design

| Item | Why rejected |
|---|---|
| **Remove the sync `_call` ABI path** (nim-ffi is callback-only) | Sync `_call` is a first-class nim-brokers ABI promise. Removing it is a breaking redesign. Adoption #2 is the correct compromise: keep the feature, close the window. |
| **`RET_STALE_WARN` progress-ping model / never time out handlers** | A different request-lifecycle contract. The slot-generation tag (PR 2) fixes H3/S5 **within** the existing timeout model. Revisit only if a progress-callback feature is wanted on its own merits. |
| **Migrate cross-thread buffers from `allocShared` to libc `c_malloc`/`c_free`** | Deep structural change across the whole MT + FFI lane. The hazard it targets is already handled by `BrokerSignalShared` + `teardownBrokerThread` (see S13 — §2.2 is closed). Not worth re-plumbing a solved problem. |
| **Fixed context pool with slot recycling** | Architectural. Only the *error-instead-of-abort* half is adopted (#8); nim-brokers' unbounded-id model stays. |
| **Replace lock-free hot paths with sharded mutexes** | The audit confirmed nim-brokers' Vyukov ring / Treiber free lists are **correct**. Only the *lifecycle glue* moves to CAS (#6); the proven primitives stay. |

### ⚠️ Not available from nim-ffi (solve from first principles)

**M1** (callback panic/exception isolation), **M5/S10** (raw `(ptr,len)` / `cstring` trust),
**S1** (CBOR depth/count limits), **B2** (mutable-ref Actions) — all shared gaps. nim-brokers is
in fact *ahead* on M1 in two places already.

---

## 11. Original full recommendation list (superseded by §10 for planning)

1. **Leak-instead-of-free on teardown timeout** (H1) — the single highest-value change, and
   nim-ffi proves it in production. Feed into `SECURITY_FIX_PLAN.md` PR 1: if the drain does not
   reach quiescence, return `err` and **do not** `freeCborCourier`. Pair with the two-round
   drain (wait → cancel → wait).
2. **Bounded `waitSlot` + courier keep-alive refcount** (H1/H2) — the compromise that keeps sync
   `_call` while removing the free-under-waiter window. (nim-ffi avoids needing this by having no
   sync path.)
3. **Never abandon a shared slot; report progress instead** (H3/S5) — adopt the `RET_STALE_WARN`
   idea as an optional progress callback, and make the timeout path reclaim-or-keep rather than
   abandon. Combine with the slot-generation tag already in the fix plan.
4. **One shared entry-point guard helper** (M6, S4) — emit `isValidCtx`-style whitelist validation
   (pointer/id must match a live registered context) plus a callback nil-check from a *single*
   codegen helper, so no entry point can forget it. Add the **type-checked handle lookup** pattern.
5. **Stop transferring caller buffer ownership; make frees typed** (M7, M5) — copy-in at the
   boundary, let the caller free its own buffer, and replace generic `_freeBuffer(void*)` with
   typed per-type frees (or the guard-header provenance tag already planned). Never hand a callback
   a nil pointer at length 0.
6. **Mutex/CAS for lifecycle glue** (M8, M9) — replace non-atomic check-then-set inits with CAS
   state machines; reserve hand-rolled ordering for the proven hot-path primitives only.
7. **Bounded queues with backpressure that reaches the ABI** (S3, S6) — a capacity + sticky
   "stuck" flag that makes the entry point reject new work beats an unbounded registry and a 50 ms
   grace-free window.
8. **Pool + recycle contexts, error on exhaustion** (S2) — bounds fds/threads and turns a host
   abort into a return code.
9. **Commit `nimble.lock`; pin `cbor_serialization` exactly** (B1, S1) — nim-ffi already does both;
   direct precedent inside the same organisation.
10. **Prefer `c_malloc`/`c_free` for buffers that cross threads** (S13-adjacent) — a strategic,
    invasive change for nim-brokers, but it retires the whole cross-thread-free hazard family that
    `LIMITATION.md` §2.2 and the `teardownBrokerThread` contract currently manage by convention.
    Worth evaluating for new code even if a full migration is out of scope.
