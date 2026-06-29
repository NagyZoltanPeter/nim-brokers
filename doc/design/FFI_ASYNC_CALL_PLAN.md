# Plan — Async FFI request (`<lib>_callAsync` + foreign response callback)

Status: **PHASE 1 DONE (branch `ffi-async-call`, off master).** Phase 2
(Python/Rust/Go wrappers) pending review. Not committed.

## Phase 1 result (verified)
- Courier runtime (`api_cbor_courier.nim`): added `CborAsyncCallMsg` + its own
  ring on `CborCourier` (separate from the sync ring/slots — sync byte-for-byte
  untouched), generic `PodRing[T]`, `CborRespMsg` + `CborRespCourier`,
  `tryEnqueueAsync`/`tryDequeueAsync`/`asyncDepthDec`, resp-courier procs.
  `asyncDepth` bounds outstanding calls so the resp ring can't overflow.
- Codegen (`api_library.nim`): `respCourier` thread-arg field + `responseCallback`
  proc type; `handleAsyncCourierMsg` + `asyncCourierPoll` on the processing
  thread; `respCourierPoll` on the delivery thread; `_createContext` alloc +
  4 error-path frees; `_shutdown` straggler drain (`-11`) + free; new
  `<lib>_callAsync` export. `mylib_callAsync` symbol confirmed.
- C header: `<lib>_response_cb_t` typedef + `_callAsync` decl.
- C++ wrapper: per-method `fooAsync(args…, std::function<void(Result<T>)>, reqId=0)`
  + one `asyncResponseTrampoline` boxing the typed decode as `userData`.
  Non-instance methods only (create-instance stays sync in Phase 1).
- Example: `examples/ffiapi/cpp_example/main.cpp` async section — runs.
- Test: `test/test_api_callAsync.nim` (6 tests) — green ORC, refc, refc+ASAN,
  release ORC/refc. Registered in `nimble testApi`.
- Regression: `test_api_library_init` green; `runTypeMapTestLibCpp` 149/149
  (async hpp codegen compiles across full type matrix).
- Pending: Python/Rust/Go wrappers + examples; `nimble test` core suite;
  Linux/Windows CI; `gitnexus_detect_changes` before commit.

---

## Phase 1.5 — per-request timeout (DONE, verified)

Goal: guarantee the response callback fires **exactly once** even if a provider
is slow/hung, and never *after* a timeout has been delivered.

**Implemented & verified.** Key correction vs the original sketch: `withTimeout`
is the WRONG tool — it cancels the dispatch on expiry, and the broker/provider
machinery swallows that cancellation into a *normal completion*, so `withTimeout`
returned `true` and masked the timeout (observed: status 0 at the 5 ms mark).
Fixed by using chronos **`race(dispFut, timerFut)`**, which leaves the loser
running; the handler decides by `dispFut.finished()`, delivers `-12` on timeout,
and best-effort `cancelSoon()`s the provider. Exactly-once holds (single
coroutine, mutually-exclusive branch; late completion is read by nobody).
Tests: 8/8 green ORC, refc, refc+ASAN, release; new "slow provider past timeout
delivers -12 exactly once" asserts `callCount == 1` after the provider's late
completion. C++ `runTypeMapTestLibCpp` 149/149; cpp_example runs with an explicit
`timeoutMs`; header emits `<LIB>_DEFAULT_ASYNC_TIMEOUT_MS 30000u`; sync
`test_api_library_init` 6/6.

### Mechanism — single-coroutine `withTimeout` (exactly-once is structural)
Each async request already runs as its own coroutine on the processing thread
(`asyncSpawn handleAsyncCourierMsg`). Wrap the dispatch:

```nim
let fut = dispatchProc(apiName, dispCtx, nimReq)
let ok =
  if effTimeout == 0: (await fut; true)          # 0 = infinite
  else: await withTimeout(fut, milliseconds(effTimeout))
if ok:
  # real response (existing success/-10 path)
else:
  status = -12; respBuf = nil; fut.cancelSoon()  # best-effort release
# ... enqueue EXACTLY ONE CborRespMsg (unchanged tail)
```

Why exactly-once holds: one coroutine, mutually-exclusive `if/else`, so it
enqueues one response. A late provider completion resolves a future nobody
awaits — its `Result` is GC'd, never enqueued → callback cannot double-fire.
`withTimeout` resolves once, atomically, on the single-threaded processing loop —
no timer-vs-completion race. The `-12` flows through the normal delivery path, so
`inFlight` / `asyncDepth` slots are released (fixes the hung-provider slot leak).

**Caveat (documented):** a provider stuck in a *blocking* (non-chronos) call
can't be cancelled — `-12` still fires exactly once, but that coroutine + its
`nimReq` leak until shutdown. Inherent to cooperative scheduling.

### Semantics (confirmed)
- ABI: `_callAsync(ctx, api, reqBuf, reqLen, reqId, timeoutMs: uint32, cb, userData)`.
  `timeoutMs == 0` → **infinite**; `N` → N ms. **Dispatch-scoped** (timer starts
  when the provider coroutine begins; queue wait is already bounded by
  `asyncDepth`). Carry `timeoutMs` in `CborAsyncCallMsg`.
- Library default **30000 ms**, configurable via a new optional
  `asyncTimeoutMs:` field in `registerBrokerLibrary`. The default is applied by
  the WRAPPERS (and exposed for raw C callers), NOT baked into the ABI — the raw
  ABI is pure mechanism (0 = infinite). Generated:
  - const `g<lib>AsyncDefaultTimeoutMs`
  - C header `#define <LIB>_DEFAULT_ASYNC_TIMEOUT_MS 30000`
- New status **`-12` = request timed out**; documented in the header, mapped to a
  `Result::err("request timed out")` in wrappers.

### Edits
- `api_cbor_courier.nim`: add `timeoutMs: uint32` to `CborAsyncCallMsg`.
- `api_library.nim`: `timeoutMs` param on `_callAsync` (→ msg); `withTimeout`
  wrap + `-12` branch in `handleAsyncCourierMsg`; emit
  `g<lib>AsyncDefaultTimeoutMs` from the `asyncTimeoutMs` config (default 30000).
- `api_codegen_cbor_h.nim`: new `timeoutMs` param in the decl, `-12` doc, the
  `#define` default constant.
- `api_codegen_cbor_hpp.nim`: `fooAsync(args…, cb, reqId=0, uint32_t timeoutMs = <LIB>_DEFAULT_ASYNC_TIMEOUT_MS)`;
  `-12` → err in the trampoline.
- `test/test_api_callAsync.nim`: slow provider + short timeout → exactly one
  `-12` callback; assert no double-fire after the provider completes late;
  per-call override; `0` = infinite path; lib-default path.
- Example: show one `getDeviceAsync(..., timeoutMs)` call.

### Verify
`nimble testApi` green; new timeout tests green ORC/refc/refc+ASAN; cpp_example
runs; sync path untouched.

---

Original plan below. Branch off `master` (proposed `ffi-async-call`). Do NOT
build on `bench-and-perf-opt` (PR #35).

Background + verified machinery: `SESSION_HANDOFF_ffi_async_response.md`,
`CBOR_Round2_PartD_EventCourier.md`. Memory: `project_ffi_async_response`.

## Goal

Add a fire-and-forget request to the generated C ABI:

```c
typedef void (*<lib>_response_cb_t)(void* userData, uint64_t reqId,
                                    int32_t status,
                                    const void* respBuf, int32_t respLen);

int32_t <lib>_callAsync(uint32_t ctx, const char* apiName,
                        void* reqBuf, int32_t reqLen,
                        uint64_t reqId,
                        <lib>_response_cb_t cb, void* userData);
```

- Returns immediately after enqueue (0 = enqueued; negative = error, never
  blocks on the condvar like `_call`).
- Response delivered later via `cb`, invoked on the **existing event delivery
  thread**.
- `userData` = opaque `void*` correlation handle, passed back verbatim. Library
  never interprets it. `reqId` carried for logging/cancel/idempotency only.
- Sync `_call` stays byte-for-byte unchanged.

## How it threads through the existing machinery

```
foreign thread          processing thread             delivery thread
─────────────           ─────────────────             ───────────────
_callAsync
  recover courier
  tryEnqueue CborCallMsg  ── courier.ring ──►
    {async=1,reqId,cb,                handleCourierMsg
     userData}                          dispatch → seq[byte],status
  fireSync(courierSignal)               encode respBuf (allocShared0)
  return 0  (no waitSlot)               tryEnqueue CborRespMsg ── respCourier.ring ──►
                                        fireBrokerSignal(deliverySignal)   respCourierPoll
                                                                             cb(userData,reqId,
                                                                                status,buf,len)
                                                                             deallocShared(buf)
```

Reuse, not reinvention: the delivery thread already runs a chronos loop with
`registerBrokerPoller(eventCourierPoll)`. We add a **second poller**
`respCourierPoll` on the same thread (the Part-D doc's reuse pattern #7).

## Components to add/modify (Nim)

### 1. `brokers/internal/api_cbor_courier.nim`
- **Sync path is byte-for-byte untouched.** `CborCallMsg`, the slot type,
  `claimSlot`/`waitSlot`/`completeSlot`/`releaseSlot`, and `CborCourier.ring`
  are NOT modified. Async lives strictly side by side.
- New `CborAsyncCallMsg`: `{apiName: array[..,char]; reqBuf: pointer; reqLen:
  int32; targetCtx: uint32; reqId: uint64; cb: pointer; userData: pointer}` on
  its **own ring** `CborAsyncCallRing` (separate from the sync ring) — async
  enqueue/drain never enters the slot/condvar machinery.
- New `CborRespMsg` (mirror of `CborEventMsg`): `{cb, userData: pointer; reqId:
  uint64; status: int32; buf: pointer; bufLen: int32}`.
- New `CborRespCourier` mirroring `CborEventCourier` (ring + dropAccount) with
  `newCborRespCourier / tryEnqueue / tryDequeue / drainAndFree / ringCap`.
  (Can reuse the event-courier ring code almost verbatim — consider factoring a
  generic ring, but DEFAULT: copy to keep the event path untouched.)

### 2. `brokers/api_library.nim`
- **Thread arg struct** (`<lib>CborThreadArg`, line ~517): add
  `respCourier: ptr CborRespCourier`.
- **`_createContext`**: allocate `arg.respCourier = newCborRespCourier(...)`
  (size from cfg, default 256); `drainAndFree` it on every error/shutdown path
  alongside `eventCourier`.
- **Delivery thread proc** (line ~1040): add `respCourierPoll()` and
  `registerBrokerPoller(respCourierPoll)` next to `eventCourierPoll`. Poll body:
  dequeue → `cast[respCbType](m.cb)(m.userData, m.reqId, m.status, m.buf,
  m.bufLen)` → `deallocShared(m.buf)`.
- **`handleCourierMsg`** (line ~1168): after dispatch, branch on `m.async`:
  - sync → `completeSlot(...)` (unchanged).
  - async → build `CborRespMsg`, `tryEnqueue(addr arg.respCourier.ring, ...)`,
    `fireBrokerSignal(arg.deliverySignal)`. On ring-full: free respBuf, throttled
    warn, drop (the response is lost; reqId logged). Decrement `inFlight`.
- **New export `<lib>_callAsync`** (sibling of `_call`, line ~1468): validate →
  recover courier+signal (same `withLock ctxs` block, bump `inFlight`) → build
  async `CborCallMsg` (no `claimSlot`) → `tryEnqueue` (false → undo inFlight,
  return -6 EAGAIN) → `fireSync(courierSignal)` → return 0.

### 3. Headers / wrappers
- `api_codegen_cbor_h.nim`: emit `<lib>_response_cb_t` typedef + `_callAsync`
  decl (always-emitted C surface).
- `api_codegen_cbor_hpp.nim`, `_py.nim`, `_rust.nim`, `_go.nim`: **per-API-method
  async sibling** emitted next to each existing sync method. Each boxes the
  user callback as `userData`; a static/extern trampoline decodes the CBOR
  response into the method's typed `Resp` and invokes the callback:
  - C++  `void fooAsync(Args…, std::function<void(Result<Resp>)> cb)`
  - Py   `foo_async(args…, cb)`
  - Rust `foo_async(args…, impl FnOnce(Result<Resp,String>))` (boxed)
  - Go   `FooAsync(args…, func(Resp, error))` (cgo.Handle)
  - C/.h raw `<lib>_callAsync` + `<lib>_response_cb_t` only (untyped).

## Key design decisions (need your call where flagged)

| Topic | Decision | Rationale |
|---|---|---|
| Correlation | `userData` opaque passthrough; no library-side reqId→cont map | matches handoff intent; standard C async idiom |
| Slots | async path does **not** `claimSlot` (slots = condvar handoff for sync only) | saves the response-slot pool for async; back-pressure via ring `queueDepth` |
| Shared vs separate call ring | **SEPARATE** async ring + `CborAsyncCallMsg`; sync ring/slot/condvar untouched | user requirement: existing sync call not touched, async lives side by side |
| Response transport | **new** `CborRespCourier`, second poller on delivery thread | event fanout (subs registry) ≠ single-cb response; keep event path untouched |
| respBuf lifetime | library `allocShared0` on processing thread, frees after `cb` returns | same contract as events; "Nim allocates/frees as today" |
| reqBuf lifetime | same as sync: ownership → processing thread, `deallocShared` once | unchanged from `_call` |
| Back-pressure | ring full → `_callAsync` returns **-6 (EAGAIN)**; caller retries/drops | bounded in-flight via existing `queueDepth` |
| **Shutdown w/ pending responses** | **CONFIRMED:** `_shutdown` drains respCourier invoking each `cb` with `status=-11` + nil buf, then frees — foreign continuations released, not leaked | chosen over silent drop |
| **inFlight decrement point** | **CONFIRMED:** decrement when response enqueued to respCourier (processing side); `_shutdown` handles stragglers via the drain above | decouples teardown from delivery-thread liveness |

## Wrapper phasing (the bulk of the line count)

Per CLAUDE.md all 5 wrappers + an example must land. **CONFIRMED split**
(Phase 1, review, then Phase 2 parity):

- **Phase 1 (prove design):** Nim C ABI + `.h` typedef/decl + **C++** typed
  `callAsync` (boxes `std::function<void(Result<T>)>` as `userData`, static C
  trampoline decodes CBOR → typed, invokes, deletes box) + a worked async
  example (`examples/ffiapi/.../main.c` or cpp_example). Verify end-to-end.
- **Phase 2 (parity):** Python (CFUNCTYPE + boxed callable), Rust
  (`extern "C"` trampoline + `Box<dyn FnOnce>`), Go (`//export` trampoline +
  `cgo.Handle`). Mirror the typemappingtestlib parity convention.

## Verification

- `nimble test`, `nimble testApi` stay green (sync path untouched).
- New test `test/test_api_callAsync.nim`: issue N async calls, assert N
  callbacks fire with correct `userData`/`status`/decoded payload, out-of-order
  OK, EAGAIN on overflow, clean shutdown with pending in flight.
- ASAN/refc build of the new test (lifetime correctness across the async
  boundary) — per global CLAUDE.md FFI rule. State refc vs ORC behavior.
- A pipelined async bench (optional) to confirm the thread-per-request ceiling
  is gone.

## Pre-edit gate (at execute time)
Run `gitnexus_impact` upstream on `registerBrokerLibrary`, `handleCourierMsg`
codegen, `CborCallMsg`, and `generateApiCborRequestBroker`; report blast radius;
`gitnexus_detect_changes` before any commit.
