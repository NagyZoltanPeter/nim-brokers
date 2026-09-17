## Issue #49, opt-out half: `invokeShutdownRequest: false` restores the historical
## behaviour — `<lib>_shutdown` does NOT invoke the declared teardown provider.
##
## A separate module because `registerBrokerLibrary` is once per module: the
## auto-invoking cases live in `test_api_shutdown_request`.

import std/atomics
import results
import testutils/unittests
import brokers/[request_broker, broker_context, api_library]
from std/strutils import contains

var gShutCalls: Atomic[int]

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

proc setupProviders(ctx: BrokerContext): Result[void, string] =
  proc initProv(
      configPath: string
  ): Future[Result[InitializeRequest, string]] {.async.} =
    return Result[InitializeRequest, string].ok(InitializeRequest(initialized: true))

  ?InitializeRequest.setProvider(ctx, initProv)

  proc shutProv(): Future[Result[ShutdownRequest, string]] {.async.} =
    discard gShutCalls.fetchAdd(1, moRelease)
    return Result[ShutdownRequest, string].ok(ShutdownRequest(status: 0))

  ?ShutdownRequest.setProvider(ctx, shutProv)

  return Result[void, string].ok()

registerBrokerLibrary:
  name:
    "sdoff"
  version:
    "0.1.0"
  initializeRequest:
    InitializeRequest
  shutdownRequest:
    ShutdownRequest
  invokeShutdownRequest:
    false

proc callShutdownRequest(ctx: uint32): int32 =
  var respBuf: pointer = nil
  var respLen: int32 = 0
  result =
    sdoff_call(ctx, "shutdown_request".cstring, nil, 0'i32, addr respBuf, addr respLen)
  if not respBuf.isNil:
    sdoff_freeBuffer(respBuf)

suite "API shutdown request opt-out (issue #49)":
  test "opting out keeps the broker on the public API surface":
    # The inverse of the default: with no auto-invocation, an explicit `_call` is
    # the only way to reach the provider, so it must stay published.
    var buf: pointer = nil
    var blen: int32 = 0
    check sdoff_listApis(addr buf, addr blen) == 0'i32
    var listed = newString(blen.int)
    if blen > 0:
      copyMem(addr listed[0], buf, blen.int)
    sdoff_freeBuffer(buf)
    check "shutdown_request" in listed

  test "_shutdown does not invoke the provider":
    gShutCalls.store(0, moRelease)
    var err: cstring = nil
    let ctx = sdoff_createContext(addr err)
    check ctx != 0'u32

    check sdoff_shutdown(ctx) == 0'i32
    check gShutCalls.load(moAcquire) == 0

  test "the provider is still reachable through the ordinary dispatch surface":
    gShutCalls.store(0, moRelease)
    var err: cstring = nil
    let ctx = sdoff_createContext(addr err)
    check ctx != 0'u32

    check callShutdownRequest(ctx) == 0'i32
    check gShutCalls.load(moAcquire) == 1

    check sdoff_shutdown(ctx) == 0'i32
    check gShutCalls.load(moAcquire) == 1 # exactly once, from the explicit call
