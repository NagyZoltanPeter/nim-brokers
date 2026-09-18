## Integration tests for the async FFI request gate (`<lib>_callAsync`)
## emitted by `registerBrokerLibrary` under `-d:BrokerFfiApi`.
##
## The test binary inlines the broker library (no .so loading) and drives
## the generated C exports as ordinary Nim procs. The foreign response
## callback is a `{.cdecl.}` proc that writes into a shared-heap result
## block whose pointer is handed through as the opaque `userData` — exactly
## the response↔request correlation idiom the ABI is designed around.
##
## Covers:
## - fire-and-forget round-trip: callback fires with the right userData,
##   reqId echo, status 0, and a decodable response payload
## - unknown apiName → status -4 delivered to the callback
## - nil callback → -7 (no enqueue, no crash)
## - many in-flight async calls all complete (out-of-order OK)
## - clean shutdown with requests still in flight: every callback fires

import std/[atomics, os]
import results
import testutils/unittests
import brokers/[request_broker, broker_context, api_library]
import brokers/internal/api_cbor_codec

# ---------------------------------------------------------------------------
# Inline mini-library
# ---------------------------------------------------------------------------

RequestBroker(API):
  type InitializeRequest = object
    initialized*: bool

  proc signature*(
    configPath: string
  ): Future[Result[InitializeRequest, string]] {.async.}

RequestBroker(API):
  type ShutdownRequest = object
    status*: int32

  proc signature*(): Future[Result[ShutdownRequest, string]] {.async.}

RequestBroker(API):
  type GetStatus = object
    online*: bool
    counter*: int32

  proc signature*(): Future[Result[GetStatus, string]] {.async.}

RequestBroker(API):
  type AddNumbers = object
    sum*: int64

  proc signature*(a: int32, b: int32): Future[Result[AddNumbers, string]] {.async.}

# A deliberately slow provider so a batch of requests can be kept in flight
# while `_shutdown` is invoked — exercises the in-flight drain + straggler path.
RequestBroker(API):
  type AddSlow = object
    sum*: int64

  proc signature*(a: int32, b: int32): Future[Result[AddSlow, string]] {.async.}

proc setupProviders(ctx: BrokerContext): Result[void, string] =
  proc initProv(
      configPath: string
  ): Future[Result[InitializeRequest, string]] {.async.} =
    return Result[InitializeRequest, string].ok(InitializeRequest(initialized: true))

  ?InitializeRequest.setProvider(ctx, initProv)

  proc shutProv(): Future[Result[ShutdownRequest, string]] {.async.} =
    return Result[ShutdownRequest, string].ok(ShutdownRequest(status: 0))

  ?ShutdownRequest.setProvider(ctx, shutProv)

  proc statusProv(): Future[Result[GetStatus, string]] {.async.} =
    return Result[GetStatus, string].ok(GetStatus(online: true, counter: 99))

  ?GetStatus.setProvider(ctx, statusProv)

  proc addProv(a: int32, b: int32): Future[Result[AddNumbers, string]] {.async.} =
    return Result[AddNumbers, string].ok(AddNumbers(sum: int64(a) + int64(b)))

  ?AddNumbers.setProvider(ctx, addProv)

  proc addSlowProv(a: int32, b: int32): Future[Result[AddSlow, string]] {.async.} =
    await sleepAsync(milliseconds(40))
    return Result[AddSlow, string].ok(AddSlow(sum: int64(a) + int64(b)))

  ?AddSlow.setProvider(ctx, addSlowProv)

  return Result[void, string].ok()

registerBrokerLibrary:
  name:
    "acbtest"
  version:
    "0.1.0"
  initializeRequest:
    InitializeRequest
  shutdownRequest:
    ShutdownRequest
  asyncQueueDepth:
    16

# ---------------------------------------------------------------------------
# Foreign-side plumbing: a shared-heap result block handed in as `userData`.
# ---------------------------------------------------------------------------

type AsyncResult = object
  done: Atomic[int]
  callCount: Atomic[int] ## number of times the callback fired — must be exactly 1
  gotReqId: uint64
  gotStatus: int32
  bufLen: int32
  buf: array[2048, byte]

proc onResp(
    userData: pointer, reqId: uint64, status: int32, respBuf: pointer, respLen: int32
) {.cdecl, gcsafe, raises: [].} =
  let r = cast[ptr AsyncResult](userData)
  discard r.callCount.fetchAdd(1, moAcquireRelease)
  r.gotReqId = reqId
  r.gotStatus = status
  if not respBuf.isNil and respLen > 0 and respLen <= int32(r.buf.len):
    copyMem(addr r.buf[0], respBuf, respLen.int)
    r.bufLen = respLen
  r.done.store(1, moRelease)

proc newResult(): ptr AsyncResult =
  cast[ptr AsyncResult](allocShared0(sizeof(AsyncResult)))

proc respBytes(r: ptr AsyncResult): seq[byte] =
  if r.bufLen <= 0:
    return @[]
  result = newSeq[byte](r.bufLen.int)
  copyMem(addr result[0], addr r.buf[0], r.bufLen.int)

proc waitDone(r: ptr AsyncResult, timeoutMs = 5000): bool =
  var waited = 0
  while r.done.load(moAcquire) == 0 and waited < timeoutMs:
    sleep(5)
    inc waited, 5
  r.done.load(moAcquire) == 1

proc allocReq(bytes: openArray[byte]): pointer =
  result = acbtest_allocBuffer(int32(bytes.len))
  if bytes.len > 0:
    copyMem(result, unsafeAddr bytes[0], bytes.len)

# ---------------------------------------------------------------------------
# Reissue-from-inside-the-callback plumbing
# ---------------------------------------------------------------------------
# The per-call depth reservation must be released when the response leaves the
# response ring, NOT after the foreign callback returns. A wrapper that bounds
# itself at exactly `asyncQueueDepth` (the Python one does) would otherwise
# collide with its own still-held reservation whenever the callback merely
# schedules a wake-up and the next call is issued before the delivery thread
# gets past the callback. Having the callback itself issue the next call turns
# that race into a deterministic check — see the regression test below.

const ReissueNotAttempted = 127'i32

var
  gReissueArmed: Atomic[int]
  gReissueRc: Atomic[int32]
  gReissueRc2: Atomic[int32]
  gReissueTarget2: ptr AsyncResult = nil
  gReissueBuf2: pointer = nil
  gReissueCtx: uint32 = 0
  gReissueBuf: pointer = nil
  gReissueLen: int32 = 0
  gReissueTarget: ptr AsyncResult = nil

proc onRespReissue(
    userData: pointer, reqId: uint64, status: int32, respBuf: pointer, respLen: int32
) {.cdecl, gcsafe, raises: [].} =
  # Exactly one callback reissues, and it does so before the normal
  # bookkeeping so `gReissueRc` is published before any waiter sees `done`.
  # The payload was encoded up-front: this must not allocate.
  if gReissueArmed.exchange(0, moAcquireRelease) == 1:
    # The generated C entry point carries no gcsafe annotation — it is meant to
    # be called from foreign code, where Nim's checker never looks. A real
    # wrapper reissues from its callback exactly like this.
    {.cast(gcsafe).}:
      let rc = acbtest_callAsync(
        gReissueCtx, "add_numbers".cstring, gReissueBuf, gReissueLen, 0xC0FFEE'u64,
        0'u32, onResp, gReissueTarget,
      )
      gReissueRc.store(rc, moRelease)
      # Second reissue from the same callback: the slot freed by this response
      # has just been consumed by the call above, so the window is full again
      # and this one must be refused. Proves the ceiling still binds even
      # when the caller is the callback itself.
      let rc2 = acbtest_callAsync(
        gReissueCtx, "add_numbers".cstring, gReissueBuf2, gReissueLen, 0xC0FFEF'u64,
        0'u32, onResp, gReissueTarget2,
      )
      gReissueRc2.store(rc2, moRelease)
  onResp(userData, reqId, status, respBuf, respLen)

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "API library async call (CBOR mode)":
  test "fire-and-forget round-trip (AddNumbers) delivers via callback":
    var err: cstring = nil
    let ctx = acbtest_createContext(addr err)
    check ctx != 0'u32

    type AddNumbersCborArgs = object
      a*: int32
      b*: int32

    let argBuf = cborEncode(AddNumbersCborArgs(a: 41'i32, b: 1'i32))
    check argBuf.isOk()
    let inBuf = allocReq(argBuf.value)

    let r = newResult()
    let rc = acbtest_callAsync(
      ctx,
      "add_numbers".cstring,
      inBuf,
      int32(argBuf.value.len),
      0xC0FFEE'u64,
      0'u32,
      onResp,
      r,
    )
    check rc == 0'i32
    check waitDone(r)
    check r.gotReqId == 0xC0FFEE'u64
    check r.gotStatus == 0'i32

    let dec = cborDecodeResultEnvelope(respBytes(r), AddNumbers)
    check dec.isOk()
    check dec.value.sum == 42'i64

    deallocShared(r)
    discard acbtest_shutdown(ctx)

  test "unknown apiName delivers framework error (-4) to the callback":
    var err: cstring = nil
    let ctx = acbtest_createContext(addr err)
    check ctx != 0'u32

    let r = newResult()
    let rc =
      acbtest_callAsync(ctx, "no_such_api".cstring, nil, 0'i32, 7'u64, 0'u32, onResp, r)
    check rc == 0'i32
    check waitDone(r)
    check r.gotReqId == 7'u64
    check r.gotStatus == -4'i32

    deallocShared(r)
    discard acbtest_shutdown(ctx)

  test "nil callback is rejected with -7 and does not enqueue":
    var err: cstring = nil
    let ctx = acbtest_createContext(addr err)
    check ctx != 0'u32

    let rc =
      acbtest_callAsync(ctx, "get_status".cstring, nil, 0'i32, 1'u64, 0'u32, nil, nil)
    check rc == -7'i32

    discard acbtest_shutdown(ctx)

  test "unknown/torn-down ctx is rejected with -5":
    let r = newResult()
    let rc = acbtest_callAsync(
      0xDEAD'u32, "get_status".cstring, nil, 0'i32, 1'u64, 0'u32, onResp, r
    )
    check rc == -5'i32
    # callback must NOT have fired
    check r.done.load(moAcquire) == 0
    deallocShared(r)

  test "many in-flight async calls all complete (out-of-order OK)":
    var err: cstring = nil
    let ctx = acbtest_createContext(addr err)
    check ctx != 0'u32

    const N = 200
    var results: array[N, ptr AsyncResult]
    for i in 0 ..< N:
      results[i] = newResult()
      # reqId encodes the issue index so we can assert echo fidelity.
      let rc = acbtest_callAsync(
        ctx, "get_status".cstring, nil, 0'i32, uint64(i), 0'u32, onResp, results[i]
      )
      # Either accepted (0) or EAGAIN (-6) under burst; retry EAGAIN.
      if rc == -6'i32:
        while acbtest_callAsync(
          ctx, "get_status".cstring, nil, 0'i32, uint64(i), 0'u32, onResp, results[i]
        ) == -6'i32
        :
          sleep(1)
      else:
        check rc == 0'i32

    var completed = 0
    for i in 0 ..< N:
      if waitDone(results[i]):
        inc completed
        check results[i].gotReqId == uint64(i)
        check results[i].gotStatus == 0'i32
        check cborDecodeResultEnvelope(respBytes(results[i]), GetStatus).isOk()
      deallocShared(results[i])
    check completed == N

    discard acbtest_shutdown(ctx)

  test "shutdown with requests in flight fires every callback":
    var err: cstring = nil
    let ctx = acbtest_createContext(addr err)
    check ctx != 0'u32

    type AddArgs = object
      a*: int32
      b*: int32

    const N = 16
    var results: array[N, ptr AsyncResult]
    for i in 0 ..< N:
      results[i] = newResult()
      let argBuf = cborEncode(AddArgs(a: int32(i), b: 1'i32))
      let inBuf = allocReq(argBuf.value)
      let rc = acbtest_callAsync(
        ctx,
        "add_slow".cstring,
        inBuf,
        int32(argBuf.value.len),
        uint64(i),
        0'u32,
        onResp,
        results[i],
      )
      check rc == 0'i32

    # Tear down while the slow providers are still running. Shutdown must
    # drain the in-flight work and ensure each callback fires (status 0 if
    # delivered in time, -11 if abandoned at teardown) — no leaked userData.
    discard acbtest_shutdown(ctx)

    for i in 0 ..< N:
      # All callbacks must have fired by the time shutdown returns + a grace.
      check waitDone(results[i])
      check (results[i].gotStatus == 0'i32 or results[i].gotStatus == -11'i32)
      deallocShared(results[i])

  test "slow provider past timeout delivers -12 exactly once":
    var err: cstring = nil
    let ctx = acbtest_createContext(addr err)
    check ctx != 0'u32

    type AddArgs = object
      a*: int32
      b*: int32

    # Provider sleeps 40ms; a 5ms timeout guarantees expiry.
    let argBuf = cborEncode(AddArgs(a: 5'i32, b: 5'i32))
    let inBuf = allocReq(argBuf.value)
    let r = newResult()
    let rc = acbtest_callAsync(
      ctx, "add_slow".cstring, inBuf, int32(argBuf.value.len), 99'u64, 5'u32, onResp, r
    )
    check rc == 0'i32
    check waitDone(r)
    check r.gotReqId == 99'u64
    check r.gotStatus == -12'i32

    # The provider completes (~40ms) AFTER the timeout already fired. Wait well
    # past it and assert the callback did NOT fire a second time.
    sleep(120)
    check r.callCount.load(moAcquire) == 1 # exactly once, never after timeout
    deallocShared(r)
    discard acbtest_shutdown(ctx)

  test "full async window returns -6 (EAGAIN) and does not fire the callback":
    var err: cstring = nil
    let ctx = acbtest_createContext(addr err)
    check ctx != 0'u32

    type AddArgs = object
      a*: int32
      b*: int32

    # asyncQueueDepth is 16 for this lib. Fill the window with slow (40ms)
    # requests so the depth reservation is held, then the next call must be
    # rejected with -6 and its callback must NOT fire.
    const Depth = 16
    var held: array[Depth, ptr AsyncResult]
    for i in 0 ..< Depth:
      held[i] = newResult()
      let argBuf = cborEncode(AddArgs(a: int32(i), b: 0'i32))
      let inBuf = allocReq(argBuf.value)
      let rc = acbtest_callAsync(
        ctx,
        "add_slow".cstring,
        inBuf,
        int32(argBuf.value.len),
        uint64(i),
        0'u32,
        onResp,
        held[i],
      )
      check rc == 0'i32

    # Window is now full — this extra call is rejected immediately.
    let overflow = newResult()
    let argBufX = cborEncode(AddArgs(a: 99'i32, b: 0'i32))
    let inBufX = allocReq(argBufX.value)
    let rcX = acbtest_callAsync(
      ctx,
      "add_slow".cstring,
      inBufX,
      int32(argBufX.value.len),
      0xBADBAD'u64,
      0'u32,
      onResp,
      overflow,
    )
    check rcX == -6'i32
    # The rejected call's callback must never fire.
    sleep(120)
    check overflow.callCount.load(moAcquire) == 0
    deallocShared(overflow)

    # The 16 accepted calls all complete normally.
    for i in 0 ..< Depth:
      check waitDone(held[i])
      check held[i].gotStatus == 0'i32
      deallocShared(held[i])

    discard acbtest_shutdown(ctx)

  test "a callback reissuing at a full window is not refused (depth released at dequeue)":
    # Regression gate for the depth-release ordering. While the reservation was
    # released only after the callback returned, this was a deterministic -6:
    # at the instant the first completion callback runs, all `Depth`
    # reservations are still held. Releasing at dequeue leaves `Depth - 1`
    # held, so the reissue is accepted. Neither outcome depends on timing —
    # callbacks are serialised on the single delivery thread, so the armed
    # callback is by definition the first response to leave the ring.
    var err: cstring = nil
    let ctx = acbtest_createContext(addr err)
    check ctx != 0'u32

    type AddArgs = object
      a*: int32
      b*: int32

    const Depth = 16

    # Encode the reissued call up-front; the callback must not allocate.
    let reArgs = cborEncode(AddArgs(a: 7'i32, b: 35'i32))
    gReissueCtx = ctx
    gReissueBuf = allocReq(reArgs.value)
    gReissueLen = int32(reArgs.value.len)
    gReissueTarget = newResult()
    gReissueBuf2 = allocReq(reArgs.value)
    gReissueTarget2 = newResult()
    gReissueRc2.store(ReissueNotAttempted, moRelease)
    gReissueRc.store(ReissueNotAttempted, moRelease)
    gReissueArmed.store(1, moRelease)

    # Fill the window exactly.
    var held: array[Depth, ptr AsyncResult]
    for i in 0 ..< Depth:
      held[i] = newResult()
      let argBuf = cborEncode(AddArgs(a: int32(i), b: 0'i32))
      let inBuf = allocReq(argBuf.value)
      let rc = acbtest_callAsync(
        ctx,
        "add_slow".cstring,
        inBuf,
        int32(argBuf.value.len),
        uint64(i),
        0'u32,
        onRespReissue,
        held[i],
      )
      check rc == 0'i32

    for i in 0 ..< Depth:
      check waitDone(held[i])
      check held[i].gotStatus == 0'i32
      deallocShared(held[i])

    # The reissue was attempted, from inside a completion callback, with the
    # window otherwise full — and it was accepted.
    check gReissueArmed.load(moAcquire) == 0
    let reissueRc = gReissueRc.load(moAcquire)
    check reissueRc == 0'i32
    # The window bound still holds from inside the callback.
    check gReissueRc2.load(moAcquire) == -6'i32
    # NB: `_callAsync` deallocates the request buffer on every return path,
    # rejections included — the caller must never free it itself. Doing so is a
    # double free that corrupts the heap and surfaces later as a SIGSEGV inside
    # an unrelated `rawAlloc`.
    deallocShared(gReissueTarget2)
    gReissueTarget2 = nil
    gReissueBuf2 = nil

    if reissueRc == 0'i32:
      check waitDone(gReissueTarget)
      check gReissueTarget.gotStatus == 0'i32
      let dec = cborDecodeResultEnvelope(respBytes(gReissueTarget), AddNumbers)
      check dec.isOk()
      check dec.value.sum == 42'i64
      deallocShared(gReissueTarget)
      gReissueTarget = nil
      gReissueBuf = nil
      discard acbtest_shutdown(ctx)
    else:
      # Regression: the reservation is being released after the callback again.
      # The checks above have already failed, so stop here — do NOT attempt an
      # orderly shutdown. Reverting the ordering locally made `_shutdown` block
      # indefinitely in this state (delivery thread parked in `awaitShutdown`),
      # and the mechanism has not been characterised. Leaking the context in a
      # test binary that is about to move on is much preferable to a CI job that
      # dies on its timeout with no usable output.
      deallocShared(gReissueTarget)
      gReissueTarget = nil
      gReissueBuf = nil

  test "generous timeout lets the slow provider complete normally":
    var err: cstring = nil
    let ctx = acbtest_createContext(addr err)
    check ctx != 0'u32

    type AddArgs = object
      a*: int32
      b*: int32

    let argBuf = cborEncode(AddArgs(a: 20'i32, b: 22'i32))
    let inBuf = allocReq(argBuf.value)
    let r = newResult()
    # 40ms provider, 5000ms budget -> completes in time.
    let rc = acbtest_callAsync(
      ctx,
      "add_slow".cstring,
      inBuf,
      int32(argBuf.value.len),
      1'u64,
      5000'u32,
      onResp,
      r,
    )
    check rc == 0'i32
    check waitDone(r)
    check r.gotStatus == 0'i32
    let dec = cborDecodeResultEnvelope(respBytes(r), AddSlow)
    check dec.isOk()
    check dec.value.sum == 42'i64
    deallocShared(r)
    discard acbtest_shutdown(ctx)
