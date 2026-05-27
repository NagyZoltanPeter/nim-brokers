## Regression tests for cross-context event-delivery isolation on teardown.
##
## The CBOR FFI emit-side fast-path gate `g<Lib>Cbor<Event>SubsCount` is a
## single process-global atomic per event type, shared by every context and
## sub-instance in the `.so`. Two teardown paths used to RESET it to 0
## (`store(0)`) instead of decrementing by the number of subs actually
## removed, which silenced event delivery for sibling contexts still
## subscribed to the same event:
##
##   * `_unsubscribe(ctx, name, handle=0)` drop-all
##   * sub-instance `close()` → `dropAllListeners` → dropAllHook
##   * `_shutdown(ctx)` (Gap 2: never decremented at all; classCtx-scoped
##     sweep now reconciles the counter for the lib ctx + alive sub-instances)
##
## These tests drive the generated C exports as ordinary Nim procs (no .so
## load) and assert that tearing down one context never silences another.

import std/[atomics, os]
import results
import testutils/unittests
import brokers/[event_broker, request_broker, broker_context, api_library]
import brokers/internal/api_cbor_codec

# ---------------------------------------------------------------------------
# Inline mini-library: one event + a request that emits it.
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

EventBroker(API):
  type Ping = object
    seqNo*: int32

RequestBroker(API):
  type TriggerPing = object
    ok*: bool

  proc signature*(n: int32): Future[Result[TriggerPing, string]] {.async.}

proc setupProviders(ctx: BrokerContext): Result[void, string] =
  proc initProv(
      configPath: string
  ): Future[Result[InitializeRequest, string]] {.async.} =
    return Result[InitializeRequest, string].ok(InitializeRequest(initialized: true))

  ?InitializeRequest.setProvider(ctx, initProv)

  proc shutProv(): Future[Result[ShutdownRequest, string]] {.async.} =
    return Result[ShutdownRequest, string].ok(ShutdownRequest(status: 0))

  ?ShutdownRequest.setProvider(ctx, shutProv)

  proc triggerProv(n: int32): Future[Result[TriggerPing, string]] {.async.} =
    await Ping.emit(ctx, Ping(seqNo: n))
    return Result[TriggerPing, string].ok(TriggerPing(ok: true))

  ?TriggerPing.setProvider(ctx, triggerProv)

  return Result[void, string].ok()

registerBrokerLibrary:
  name:
    "cbevt"
  version:
    "0.1.0"
  initializeRequest:
    InitializeRequest
  shutdownRequest:
    ShutdownRequest

# ---------------------------------------------------------------------------
# Foreign-callback side: per-subscriber delivery counters addressed via
# userData. The callback is the generated cdecl event-callback ABI.
# ---------------------------------------------------------------------------

var aCount: Atomic[int]
var bCount: Atomic[int]

proc onPing(
    ctx: uint32,
    eventName: cstring,
    payloadBuf: pointer,
    payloadLen: int32,
    userData: pointer,
) {.cdecl, gcsafe, raises: [].} =
  if not userData.isNil:
    discard cast[ptr Atomic[int]](userData)[].fetchAdd(1, moRelease)

type TriggerPingArgs = object
  n*: int32

proc triggerPing(ctx: uint32, n: int32) =
  ## Drive the `trigger_ping` request whose provider emits `Ping`.
  let args = cborEncode(TriggerPingArgs(n: n))
  doAssert args.isOk()
  var inBuf = cbevt_allocBuffer(int32(args.value.len))
  if args.value.len > 0:
    copyMem(inBuf, unsafeAddr args.value[0], args.value.len)
  var respBuf: pointer = nil
  var respLen: int32 = 0
  let status = cbevt_call(
    ctx,
    "trigger_ping".cstring,
    inBuf,
    int32(args.value.len),
    addr respBuf,
    addr respLen,
  )
  doAssert status == 0'i32, "trigger_ping failed: " & $status
  if not respBuf.isNil:
    cbevt_freeBuffer(respBuf)

proc waitForCount(p: ptr Atomic[int], target: int, timeoutMs: int): bool =
  ## Poll until the counter reaches `target` (emit→courier→delivery thread is
  ## async/fire-and-forget, so delivery lands shortly after the request returns).
  var waited = 0
  while waited < timeoutMs:
    if p[].load(moAcquire) >= target:
      return true
    sleep(2)
    waited += 2
  p[].load(moAcquire) >= target

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "API event teardown isolation (CBOR mode)":
  test "_unsubscribe(handle=0) on B does not silence A (Gap 1)":
    aCount.store(0)
    bCount.store(0)
    var e1, e2: cstring = nil
    let ctxA = cbevt_createContext(addr e1)
    let ctxB = cbevt_createContext(addr e2)
    check ctxA != 0'u32
    check ctxB != 0'u32

    check cbevt_subscribe(ctxA, "ping".cstring, onPing, addr aCount) >= 2'u64
    check cbevt_subscribe(ctxB, "ping".cstring, onPing, addr bCount) >= 2'u64

    triggerPing(ctxA, 1)
    check waitForCount(addr aCount, 1, 2000)

    # Drop ALL of B's subscriptions — the path that previously store(0)'d the
    # shared counter and silenced A.
    check cbevt_unsubscribe(ctxB, "ping".cstring, 0'u64) == 0'i32

    triggerPing(ctxA, 2)
    check waitForCount(addr aCount, 2, 2000) # FAILS before the fix (gate stuck at 0)

    discard cbevt_shutdown(ctxA)
    discard cbevt_shutdown(ctxB)

  test "_shutdown(B) with a live subscriber does not silence A (Gap 2)":
    aCount.store(0)
    bCount.store(0)
    var e1, e2: cstring = nil
    let ctxA = cbevt_createContext(addr e1)
    let ctxB = cbevt_createContext(addr e2)
    check ctxA != 0'u32
    check ctxB != 0'u32

    check cbevt_subscribe(ctxA, "ping".cstring, onPing, addr aCount) >= 2'u64
    # B subscribes but never unsubscribes — its subs must be drained by the
    # classCtx-scoped sweep in _shutdown, decrementing the counter by B's count.
    check cbevt_subscribe(ctxB, "ping".cstring, onPing, addr bCount) >= 2'u64

    check cbevt_shutdown(ctxB) == 0'i32

    triggerPing(ctxA, 1)
    check waitForCount(addr aCount, 1, 2000)

    discard cbevt_shutdown(ctxA)

  test "gate closes when the last subscriber leaves (decrement reaches 0)":
    aCount.store(0)
    var e1: cstring = nil
    let ctxA = cbevt_createContext(addr e1)
    check ctxA != 0'u32

    check cbevt_subscribe(ctxA, "ping".cstring, onPing, addr aCount) >= 2'u64
    triggerPing(ctxA, 1)
    check waitForCount(addr aCount, 1, 2000)

    # Removing the only subscriber must drive the counter to exactly 0 so the
    # emit-side gate short-circuits — proving the fix decrements, not disables.
    check cbevt_unsubscribe(ctxA, "ping".cstring, 0'u64) == 0'i32

    let before = aCount.load(moAcquire)
    triggerPing(ctxA, 2)
    sleep(300) # give any (erroneous) delivery time to land
    check aCount.load(moAcquire) == before

    discard cbevt_shutdown(ctxA)
