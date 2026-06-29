# Follow-up — zero-copy request decode (drop the reqBuf → seq copy)

Status: **DEFERRED — not scheduled.** Captured during the `_callAsync` review
(branch `ffi-async-call`). Do NOT implement as part of the async-call work; this
is a separate cross-cutting optimization that must land on the sync and async
lanes together.

## What

Today both FFI request handlers copy the incoming shared request buffer into a
Nim-GC `seq[byte]` and immediately free the shared buffer:

- sync: `handleCourierMsg` — `brokers/api_library.nim:1216-1218`
- async: `handleAsyncCourierMsg` — `brokers/api_library.nim:1273-1275`

```nim
var nimReq = newSeq[byte](m.reqLen.int)
if m.reqLen > 0 and not m.reqBuf.isNil:
  copyMem(addr nimReq[0], m.reqBuf, m.reqLen.int)   # the copy we want to remove
if not m.reqBuf.isNil:
  deallocShared(m.reqBuf)
```

The copy exists for two reasons (see review notes):
1. **Interface impedance** — `<lib>CborDispatch(apiName, ctx, nimReq)` and every
   per-type CBOR adapter are written against `seq[byte]`; `m.reqBuf` is a raw
   `allocShared0` pointer.
2. **Lifetime simplification across `await`** — freeing the shared buffer before
   the dispatch/provider `await` chain means nothing downstream has to reason
   about shared-buffer ownership across suspensions.

## Proposed change

Decode directly from a **non-owning view** (`openArray[byte]` /
`ptr UncheckedArray[byte]` + len) over `m.reqBuf`, then `deallocShared(m.reqBuf)`
right after decode completes — the CBOR decode already copies bytes into typed
argument structs, so the raw bytes only need to live until decode returns, not
across the provider call.

Net effect: removes one `allocShared`-class alloc + one `memcpy` per request on
both the sync and async hot paths.

## Why it's not trivial (why it's a follow-up, not part of Phase 1)

- The decode is currently **inside** `dispatchProc`, which also runs the provider
  and awaits. To free "after decode, before provider," the dispatch codegen must
  **split decode from invoke** so the handler can free the view before the
  provider's first suspension. Alternatively keep the shared buffer alive to the
  end of dispatch — simpler but holds shared memory across provider awaits
  (weaker lifetime story; measure before choosing).
- The `seq[byte]` signature is **shared** across sync `_call`, async
  `_callAsync`, and the entire CBOR codec/adapter surface. Changing it to a view
  type ripples through `api_request_broker_cbor.nim`, the generated
  `<lib>CborDispatch`, and every per-type adapter. Must stay byte-for-byte
  behaviour-compatible on both lanes.
- Request payloads are small (CBOR arg blobs, tens–hundreds of bytes), so the
  copy is cheap relative to the thread hop + provider call. **Benchmark first**
  to confirm the optimization is worth the codegen churn.

## Scope / acceptance

- Single change that benefits **both** sync and async handlers (no async-only
  fork).
- `nimble test` + `nimble testApi` green; `test_api_callAsync` green incl.
  refc + ASAN (no use-after-free on the now-shorter-lived shared buffer).
- A before/after micro-bench on the request hot path showing a measurable win;
  if the win is within noise, **close as not-worth-it**.

## Pointers

- Handlers: `brokers/api_library.nim` (`handleCourierMsg`,
  `handleAsyncCourierMsg`).
- Dispatch + adapters: `brokers/internal/api_request_broker_cbor.nim`,
  generated `<lib>CborDispatch`.
- Courier message types (`reqBuf`/`reqLen`): `brokers/internal/api_cbor_courier.nim`
  (`CborCallMsg`, `CborAsyncCallMsg`).
- Async-call context: `doc/design/FFI_ASYNC_CALL_PLAN.md`.
