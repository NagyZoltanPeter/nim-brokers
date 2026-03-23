import testutils/unittests
import chronos
import std/[atomics, os]

import brokers/[event_broker, request_broker, broker_context, api_library]

## ---------------------------------------------------------------------------
## API library init tests
## ---------------------------------------------------------------------------
## This test exercises the full registerBrokerLibrary lifecycle and verifies
## that after lib_create() returns, both the delivery thread and processing
## thread are ready immediately without requiring caller-side sleeps.

RequestBroker(API):
  type CreateRequest = object
    initialized*: bool

  proc signature*(): Future[Result[CreateRequest, string]] {.async.}

RequestBroker(API):
  type DestroyRequest = object
    status*: int32

  proc signature*(): Future[Result[DestroyRequest, string]] {.async.}

RequestBroker(API):
  type PingRequest = object
    value*: int32

  proc signature*(): Future[Result[PingRequest, string]] {.async.}

EventBroker(API):
  type ReadyEvent = object
    value*: int32

var gLibCtx {.threadvar.}: BrokerContext

proc setupProviders(ctx: BrokerContext) =
  gLibCtx = ctx

  discard CreateRequest.setProvider(
    ctx,
    proc(): Future[Result[CreateRequest, string]] {.closure, async.} =
      await ReadyEvent.emit(gLibCtx, ReadyEvent(value: 7))
      return ok(CreateRequest(initialized: true)),
  )

  discard DestroyRequest.setProvider(
    ctx,
    proc(): Future[Result[DestroyRequest, string]] {.closure, async.} =
      return ok(DestroyRequest(status: 0)),
  )

  discard PingRequest.setProvider(
    ctx,
    proc(): Future[Result[PingRequest, string]] {.closure, async.} =
      return ok(PingRequest(value: 99)),
  )

registerBrokerLibrary:
  name: "apitestlib"
  createRequest: CreateRequest
  destroyRequest: DestroyRequest

var gReadyCallbackCount: Atomic[int32]
var gReadyCallbackValue: Atomic[int32]

proc readyCallback(value: int32) {.cdecl.} =
  gReadyCallbackValue.store(value)
  discard gReadyCallbackCount.fetchAdd(1)

proc clearError(msg: cstring) =
  if not msg.isNil:
    freeCString(msg)

suite "API library init":
  test "lib_create returns only after immediate requests and listener registration are ready":
    gReadyCallbackCount.store(0)
    gReadyCallbackValue.store(-1)

    apitestlib_initialize()
    let ctx = apitestlib_create()
    check ctx != 0'u32

    let handle = onReadyEvent(ctx, readyCallback)
    check handle > 0'u64

    let pingRes = ping_request_request(ctx)
    check pingRes.error_message.isNil()
    check pingRes.value == 99
    clearError(pingRes.error_message)

    let createRes = create_request_request(ctx)
    check createRes.error_message.isNil()
    check createRes.initialized == true
    clearError(createRes.error_message)

    var waitedMs = 0
    while gReadyCallbackCount.load() == 0 and waitedMs < 1000:
      sleep(10)
      waitedMs += 10

    check gReadyCallbackCount.load() >= 1
    check gReadyCallbackValue.load() == 7

    offReadyEvent(ctx, handle)

    let destroyRes = destroy_request_request(ctx)
    check destroyRes.error_message.isNil()
    check destroyRes.status == 0
    clearError(destroyRes.error_message)

    apitestlib_shutdown(ctx)