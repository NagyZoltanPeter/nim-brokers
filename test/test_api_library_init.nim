import testutils/unittests
import chronos
import std/[algorithm, atomics, locks, os]

import brokers/[api_library, broker_context, event_broker, request_broker]

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
var gReadyCallbackCount: Atomic[int32]
var gReadyCallbackValue: Atomic[int32]
var gSetupProvidersCount: Atomic[int32]
var gSetupPingBucketCount: Atomic[int32]
var gSetupDestroyBucketCount: Atomic[int32]
var gSetupCreateBucketCount: Atomic[int32]

proc recordRequestBrokerBuckets() =
  withLock(gCreateRequestMtLock):
    gSetupCreateBucketCount.store(int32(gCreateRequestMtBucketCount))
  withLock(gDestroyRequestMtLock):
    gSetupDestroyBucketCount.store(int32(gDestroyRequestMtBucketCount))
  withLock(gPingRequestMtLock):
    gSetupPingBucketCount.store(int32(gPingRequestMtBucketCount))

proc resetSetupBucketState() =
  gSetupPingBucketCount.store(-1)
  gSetupDestroyBucketCount.store(-1)
  gSetupCreateBucketCount.store(-1)

proc setupProviders(ctx: BrokerContext) =
  gLibCtx = ctx
  discard gSetupProvidersCount.fetchAdd(1)

  let createProviderRes = CreateRequest.setProvider(
    ctx,
    proc(): Future[Result[CreateRequest, string]] {.closure, async.} =
      await ReadyEvent.emit(gLibCtx, ReadyEvent(value: 7))
      return ok(CreateRequest(initialized: true)),
  )
  doAssert createProviderRes.isOk(), createProviderRes.error()

  let destroyProviderRes = DestroyRequest.setProvider(
    ctx,
    proc(): Future[Result[DestroyRequest, string]] {.closure, async.} =
      return ok(DestroyRequest(status: 0)),
  )
  doAssert destroyProviderRes.isOk(), destroyProviderRes.error()

  let pingProviderRes = PingRequest.setProvider(
    ctx,
    proc(): Future[Result[PingRequest, string]] {.closure, async.} =
      return ok(PingRequest(value: 99)),
  )
  doAssert pingProviderRes.isOk(), pingProviderRes.error()

  recordRequestBrokerBuckets()

registerBrokerLibrary:
  name:
    "apitestlib"
  createRequest:
    CreateRequest
  destroyRequest:
    DestroyRequest

proc readyCallback(value: int32) {.cdecl.} =
  gReadyCallbackValue.store(value)
  discard gReadyCallbackCount.fetchAdd(1)

proc clearError(msg: cstring) =
  if not msg.isNil:
    freeCString(msg)

proc pingBucketCtxs(): seq[uint32] =
  withLock(gPingRequestMtLock):
    for i in 0 ..< gPingRequestMtBucketCount:
      result.add(uint32(gPingRequestMtBuckets[i].brokerCtx))

proc destroyBucketCtxs(): seq[uint32] =
  withLock(gDestroyRequestMtLock):
    for i in 0 ..< gDestroyRequestMtBucketCount:
      result.add(uint32(gDestroyRequestMtBuckets[i].brokerCtx))

proc createBucketCtxs(): seq[uint32] =
  withLock(gCreateRequestMtLock):
    for i in 0 ..< gCreateRequestMtBucketCount:
      result.add(uint32(gCreateRequestMtBuckets[i].brokerCtx))

proc assertSingleContextBuckets(ctx: uint32) =
  check gSetupProvidersCount.load() >= 1
  check gSetupPingBucketCount.load() == 1
  check gSetupDestroyBucketCount.load() == 1
  check gSetupCreateBucketCount.load() == 1
  check pingBucketCtxs() == @[ctx]
  check destroyBucketCtxs() == @[ctx]
  check createBucketCtxs() == @[ctx]

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

    var activeCtxCount = -1
    withLock(gapitestlibCtxsLock):
      activeCtxCount = gapitestlibCtxs.len
    check activeCtxCount == 0
    check pingBucketCtxs().len == 0
    check destroyBucketCtxs().len == 0
    check createBucketCtxs().len == 0

  test "shutdown removes registry entry and repeated create/shutdown cycles work":
    apitestlib_initialize()

    for _ in 0 ..< 3:
      resetSetupBucketState()
      let ctx = apitestlib_create()
      check ctx != 0'u32

      var activeCtxCount = -1
      withLock(gapitestlibCtxsLock):
        activeCtxCount = gapitestlibCtxs.len
      check activeCtxCount == 1
      assertSingleContextBuckets(ctx)

      let pingRes = ping_request_request(ctx)
      if not pingRes.error_message.isNil:
        echo "ping buckets: ", pingBucketCtxs()
        echo "destroy buckets: ", destroyBucketCtxs()
        echo "create buckets: ", createBucketCtxs()
        echo "ping_request_request error: ", $pingRes.error_message
      check pingRes.error_message.isNil()
      check pingRes.value == 99
      clearError(pingRes.error_message)

      let destroyRes = destroy_request_request(ctx)
      if not destroyRes.error_message.isNil:
        echo "ping buckets: ", pingBucketCtxs()
        echo "destroy buckets: ", destroyBucketCtxs()
        echo "create buckets: ", createBucketCtxs()
        echo "destroy_request_request error: ", $destroyRes.error_message
      check destroyRes.error_message.isNil()
      check destroyRes.status == 0
      clearError(destroyRes.error_message)

      apitestlib_shutdown(ctx)

      withLock(gapitestlibCtxsLock):
        activeCtxCount = gapitestlibCtxs.len
      check activeCtxCount == 0

  test "two library instances coexist and remain independently usable":
    apitestlib_initialize()

    let ctx1 = apitestlib_create()
    let ctx2 = apitestlib_create()
    check ctx1 != 0'u32
    check ctx2 != 0'u32
    check ctx1 != ctx2

    var activeCtxCount = -1
    withLock(gapitestlibCtxsLock):
      activeCtxCount = gapitestlibCtxs.len
    check activeCtxCount == 2
    check pingBucketCtxs().sorted() == @[ctx1, ctx2].sorted()
    check destroyBucketCtxs().sorted() == @[ctx1, ctx2].sorted()
    check createBucketCtxs().sorted() == @[ctx1, ctx2].sorted()

    let pingRes1 = ping_request_request(ctx1)
    check pingRes1.error_message.isNil()
    check pingRes1.value == 99
    clearError(pingRes1.error_message)

    let pingRes2 = ping_request_request(ctx2)
    check pingRes2.error_message.isNil()
    check pingRes2.value == 99
    clearError(pingRes2.error_message)

    let createRes1 = create_request_request(ctx1)
    check createRes1.error_message.isNil()
    check createRes1.initialized == true
    clearError(createRes1.error_message)

    let createRes2 = create_request_request(ctx2)
    check createRes2.error_message.isNil()
    check createRes2.initialized == true
    clearError(createRes2.error_message)

    apitestlib_shutdown(ctx1)

    withLock(gapitestlibCtxsLock):
      activeCtxCount = gapitestlibCtxs.len
    check activeCtxCount == 1
    check pingBucketCtxs() == @[ctx2]
    check destroyBucketCtxs() == @[ctx2]
    check createBucketCtxs() == @[ctx2]

    let destroyRes2 = destroy_request_request(ctx2)
    check destroyRes2.error_message.isNil()
    check destroyRes2.status == 0
    clearError(destroyRes2.error_message)

    apitestlib_shutdown(ctx2)

    withLock(gapitestlibCtxsLock):
      activeCtxCount = gapitestlibCtxs.len
    check activeCtxCount == 0
    check pingBucketCtxs().len == 0
    check destroyBucketCtxs().len == 0
    check createBucketCtxs().len == 0

  test "repeated initialize create shutdown sequences remain usable":
    for _ in 0 ..< 2:
      apitestlib_initialize()
      let ctx = apitestlib_create()
      check ctx != 0'u32

      let pingRes = ping_request_request(ctx)
      check pingRes.error_message.isNil()
      check pingRes.value == 99
      clearError(pingRes.error_message)

      let createRes = create_request_request(ctx)
      check createRes.error_message.isNil()
      check createRes.initialized == true
      clearError(createRes.error_message)

      let destroyRes = destroy_request_request(ctx)
      check destroyRes.error_message.isNil()
      check destroyRes.status == 0
      clearError(destroyRes.error_message)

      apitestlib_shutdown(ctx)

      var activeCtxCount = -1
      withLock(gapitestlibCtxsLock):
        activeCtxCount = gapitestlibCtxs.len
      check activeCtxCount == 0
      check pingBucketCtxs().len == 0
      check destroyBucketCtxs().len == 0
      check createBucketCtxs().len == 0
