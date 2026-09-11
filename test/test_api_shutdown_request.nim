## Regression tests for issue #49 — `<lib>_shutdown` invokes the declared
## `shutdownRequest` provider.
##
## Before the fix, `config.shutdownRequest` reached exactly one emitted
## construct: a `when not compiles` existence assertion. `<lib>_shutdown` tore
## down the transport (threads, couriers, subscription registry) and never
## touched the provider, so a teardown provider that flushed state lost that
## work on every clean shutdown, with no diagnostic.
##
## The invocation rides a reserved apiName (`__shutdown_request`) through the
## same courier `__release_instance` uses, so it runs on the PROCESSING thread
## (which owns the provider's MT broker bucket) while BOTH threads are still
## alive (so an event emitted as the provider's last act is still fanned out).
##
## These tests drive the generated C exports as ordinary Nim procs (no .so
## load), matching `test_api_event_teardown_isolation`.

import std/[atomics, monotimes, os]
# Selective: a plain `import std/times` would shadow chronos's `milliseconds`
# for the whole module, including the code `registerBrokerLibrary` generates here.
from std/times import inMilliseconds
import results
import testutils/unittests
import brokers/[event_broker, request_broker, broker_context, api_library]
import brokers/internal/api_cbor_codec

# ---------------------------------------------------------------------------
# Provider behaviour is selected per test through a process-global mode, so one
# library (one `registerBrokerLibrary` per module) can exercise every path.
# ---------------------------------------------------------------------------

type ShutModeKind = enum
  smOk ## return ok
  smErr ## return err — teardown must still complete
  smEmit ## emit an event as the last act
  smHang ## sleep well past the configured budget

var gShutMode: Atomic[int]
var gShutCalls: Atomic[int] ## how many times the provider ran
var gShutDone: Atomic[int] ## provider reached its return statement
var gRegisterShutProv: Atomic[int] ## 0 = setupProviders skips registration

proc setMode(m: ShutModeKind) =
  gShutMode.store(int(m), moRelease)
  gShutCalls.store(0, moRelease)
  gShutDone.store(0, moRelease)
  gRegisterShutProv.store(1, moRelease)

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
  type Farewell = object
    seqNo*: int32

RequestBroker(API):
  type Ping = object
    ok*: bool

  proc signature*(): Future[Result[Ping, string]] {.async.}

proc setupProviders(ctx: BrokerContext): Result[void, string] =
  proc initProv(
      configPath: string
  ): Future[Result[InitializeRequest, string]] {.async.} =
    return Result[InitializeRequest, string].ok(InitializeRequest(initialized: true))

  ?InitializeRequest.setProvider(ctx, initProv)

  proc shutProv(): Future[Result[ShutdownRequest, string]] {.async.} =
    discard gShutCalls.fetchAdd(1, moRelease)
    case ShutModeKind(gShutMode.load(moAcquire))
    of smOk:
      discard
    of smErr:
      gShutDone.store(1, moRelease)
      return Result[ShutdownRequest, string].err("teardown refused on purpose")
    of smEmit:
      Farewell.emit(ctx, Farewell(seqNo: 99))
    of smHang:
      # Far beyond `shutdownRequestTimeoutMs` below. The processing thread races
      # this against its timer and completes the response slot without it.
      # Int overload on purpose: `std/times.milliseconds` shadows chronos's.
      let s = catch:
        await sleepAsync(5000)
      if s.isErr():
        # The processing thread best-effort-cancels the loser of the timeout
        # race. Report it instead of falling through, so `gShutDone` stays 0
        # and the test can tell "cancelled" from "completed late".
        return Result[ShutdownRequest, string].err("cancelled by the shutdown budget")
    gShutDone.store(1, moRelease)
    return Result[ShutdownRequest, string].ok(ShutdownRequest(status: 0))

  # Skipped on purpose by one test: a library that never registers the provider
  # must still tear down cleanly (the broker answers "no provider", which is
  # logged and ignored).
  if gRegisterShutProv.load(moAcquire) == 1:
    ?ShutdownRequest.setProvider(ctx, shutProv)

  proc pingProv(): Future[Result[Ping, string]] {.async.} =
    Farewell.emit(ctx, Farewell(seqNo: 1))
    return Result[Ping, string].ok(Ping(ok: true))

  ?Ping.setProvider(ctx, pingProv)

  return Result[void, string].ok()

registerBrokerLibrary:
  name:
    "sdreq"
  version:
    "0.1.0"
  initializeRequest:
    InitializeRequest
  shutdownRequest:
    ShutdownRequest
  # Short on purpose: the hang case must not stretch the suite.
  shutdownRequestTimeoutMs:
    300

# ---------------------------------------------------------------------------
# Foreign-callback side for the "provider emits as its last act" case.
# ---------------------------------------------------------------------------

var gFarewells: Atomic[int]

proc onFarewell(
    ctx: uint32,
    eventName: cstring,
    payloadBuf: pointer,
    payloadLen: int32,
    userData: pointer,
) {.cdecl, gcsafe, raises: [].} =
  if not userData.isNil:
    discard cast[ptr Atomic[int]](userData)[].fetchAdd(1, moRelease)

proc callShutdownRequest(ctx: uint32): int32 =
  ## Drive the teardown provider through the ordinary dispatch surface — the
  ## only way to reach it before this fix.
  var respBuf: pointer = nil
  var respLen: int32 = 0
  result =
    sdreq_call(ctx, "shutdown_request".cstring, nil, 0'i32, addr respBuf, addr respLen)
  if not respBuf.isNil:
    sdreq_freeBuffer(respBuf)

proc callPing(ctx: uint32): int32 =
  var respBuf: pointer = nil
  var respLen: int32 = 0
  result = sdreq_call(ctx, "ping".cstring, nil, 0'i32, addr respBuf, addr respLen)
  if not respBuf.isNil:
    sdreq_freeBuffer(respBuf)

proc elapsedMs(since: MonoTime): int64 =
  (getMonoTime() - since).inMilliseconds

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "API shutdown request invocation (issue #49)":
  test "_shutdown invokes the declared teardown provider":
    setMode(smOk)
    var err: cstring = nil
    let ctx = sdreq_createContext(addr err)
    check ctx != 0'u32
    check gShutCalls.load(moAcquire) == 0 # not before shutdown

    check sdreq_shutdown(ctx) == 0'i32
    check gShutCalls.load(moAcquire) == 1
    check gShutDone.load(moAcquire) == 1

  test "provider still runs after ordinary requests have been served":
    setMode(smOk)
    var err: cstring = nil
    let ctx = sdreq_createContext(addr err)
    check ctx != 0'u32
    check callPing(ctx) == 0'i32

    check sdreq_shutdown(ctx) == 0'i32
    check gShutCalls.load(moAcquire) == 1

  # Control for the case below: proves the emit → courier → delivery chain works
  # during normal operation, so a failure there is specific to the teardown path.
  test "control: emit from an ordinary provider reaches a subscriber":
    setMode(smOk)
    gFarewells.store(0, moRelease)
    var err: cstring = nil
    let ctx = sdreq_createContext(addr err)
    check ctx != 0'u32
    check sdreq_subscribe(ctx, "farewell".cstring, onFarewell, addr gFarewells) >= 2'u64
    check callPing(ctx) == 0'i32
    var waited = 0
    while gFarewells.load(moAcquire) == 0 and waited < 2000:
      sleep(2)
      waited += 2
    check gFarewells.load(moAcquire) == 1
    discard sdreq_shutdown(ctx)

  test "an event emitted as the provider's last act reaches a subscriber":
    setMode(smEmit)
    gFarewells.store(0, moRelease)
    var err: cstring = nil
    let ctx = sdreq_createContext(addr err)
    check ctx != 0'u32
    check sdreq_subscribe(ctx, "farewell".cstring, onFarewell, addr gFarewells) >= 2'u64

    # Both threads are still alive when the provider runs, and `_shutdown` hands
    # the event courier off to the delivery thread before setting the shutdown
    # flag — so the callback must have fired by the time `_shutdown` returns.
    check sdreq_shutdown(ctx) == 0'i32
    check gShutCalls.load(moAcquire) == 1
    check gFarewells.load(moAcquire) == 1

  test "a failing provider does not abort teardown":
    setMode(smErr)
    var err: cstring = nil
    let ctx = sdreq_createContext(addr err)
    check ctx != 0'u32

    check sdreq_shutdown(ctx) == 0'i32 # error is logged, never propagated
    check gShutCalls.load(moAcquire) == 1

    # The context is fully gone: a second shutdown finds no entry.
    check sdreq_shutdown(ctx) == -1'i32

  test "a hung provider does not stall teardown past its budget":
    setMode(smHang)
    var err: cstring = nil
    let ctx = sdreq_createContext(addr err)
    check ctx != 0'u32

    let started = getMonoTime()
    check sdreq_shutdown(ctx) == 0'i32
    let took = elapsedMs(started)
    check gShutCalls.load(moAcquire) == 1
    check gShutDone.load(moAcquire) == 0 # provider never finished
    # 300 ms budget + thread join + free. Generous upper bound, but far below
    # the provider's 5 s sleep, which is what an unbounded wait would cost.
    check took < 3000

  test "an explicit shutdown_request call plus _shutdown runs it twice":
    setMode(smOk)
    var err: cstring = nil
    let ctx = sdreq_createContext(addr err)
    check ctx != 0'u32

    check callShutdownRequest(ctx) == 0'i32
    check gShutCalls.load(moAcquire) == 1

    # Auto-invocation is unconditional; a library that drives teardown itself
    # either makes its provider idempotent or opts out with
    # `invokeShutdownRequest: false` (see test_api_shutdown_request_optout).
    check sdreq_shutdown(ctx) == 0'i32
    check gShutCalls.load(moAcquire) == 2

  test "an unregistered provider does not break teardown":
    setMode(smOk)
    gRegisterShutProv.store(0, moRelease) # setupProviders will skip it
    var err: cstring = nil
    let ctx = sdreq_createContext(addr err)
    check ctx != 0'u32

    check sdreq_shutdown(ctx) == 0'i32
    check gShutCalls.load(moAcquire) == 0

  test "each context gets its own invocation":
    setMode(smOk)
    var e1, e2: cstring = nil
    let ctxA = sdreq_createContext(addr e1)
    let ctxB = sdreq_createContext(addr e2)
    check ctxA != 0'u32
    check ctxB != 0'u32

    check sdreq_shutdown(ctxA) == 0'i32
    check gShutCalls.load(moAcquire) == 1
    check sdreq_shutdown(ctxB) == 0'i32
    check gShutCalls.load(moAcquire) == 2
