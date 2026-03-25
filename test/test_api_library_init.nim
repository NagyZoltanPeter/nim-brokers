import testutils/unittests
import chronos
import std/[algorithm, atomics, locks, os]

import brokers/[api_library, broker_context, event_broker, request_broker]

RequestBroker(API):
  type InitializeRequest = object
    initialized*: bool

  proc signature*(): Future[Result[InitializeRequest, string]] {.async.}

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
var gSetupInitializeBucketCount: Atomic[int32]
var gSetupProvidersShouldFail: Atomic[int32]

proc recordRequestBrokerBuckets() =
  withLock(gInitializeRequestMtLock):
    gSetupInitializeBucketCount.store(int32(gInitializeRequestMtBucketCount))
  withLock(gDestroyRequestMtLock):
    gSetupDestroyBucketCount.store(int32(gDestroyRequestMtBucketCount))
  withLock(gPingRequestMtLock):
    gSetupPingBucketCount.store(int32(gPingRequestMtBucketCount))

proc resetSetupBucketState() =
  gSetupPingBucketCount.store(-1)
  gSetupDestroyBucketCount.store(-1)
  gSetupInitializeBucketCount.store(-1)

proc setupProviders(ctx: BrokerContext): Result[void, string] =
  gLibCtx = ctx
  discard gSetupProvidersCount.fetchAdd(1)

  if gSetupProvidersShouldFail.load() == 1:
    return err("simulated setupProviders failure")

  let initializeProviderRes = InitializeRequest.setProvider(
    ctx,
    proc(): Future[Result[InitializeRequest, string]] {.closure, async.} =
      await ReadyEvent.emit(gLibCtx, ReadyEvent(value: 7))
      return ok(InitializeRequest(initialized: true)),
  )
  if initializeProviderRes.isErr():
    return err(
      "failed to register InitializeRequest provider: " & initializeProviderRes.error()
    )

  let destroyProviderRes = DestroyRequest.setProvider(
    ctx,
    proc(): Future[Result[DestroyRequest, string]] {.closure, async.} =
      return ok(DestroyRequest(status: 0)),
  )
  if destroyProviderRes.isErr():
    return
      err("failed to register DestroyRequest provider: " & destroyProviderRes.error())

  let pingProviderRes = PingRequest.setProvider(
    ctx,
    proc(): Future[Result[PingRequest, string]] {.closure, async.} =
      return ok(PingRequest(value: 99)),
  )
  if pingProviderRes.isErr():
    return err("failed to register PingRequest provider: " & pingProviderRes.error())

  recordRequestBrokerBuckets()
  ok()

registerBrokerLibrary:
  name:
    "apitestlib"
  initializeRequest:
    InitializeRequest
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

proc initializeBucketCtxs(): seq[uint32] =
  withLock(gInitializeRequestMtLock):
    for i in 0 ..< gInitializeRequestMtBucketCount:
      result.add(uint32(gInitializeRequestMtBuckets[i].brokerCtx))

proc freeCreateContextResult(r: var apitestlibCreateContextResult) =
  free_apitestlib_create_context_result(addr r)

proc createContext(): uint32 =
  var createContextRes = apitestlib_createContext()
  defer:
    freeCreateContextResult(createContextRes)
  check createContextRes.error_message.isNil()
  clearError(createContextRes.error_message)
  result = createContextRes.ctx

proc assertSingleContextBuckets(ctx: uint32) =
  check gSetupProvidersCount.load() >= 1
  check gSetupPingBucketCount.load() == 1
  check gSetupDestroyBucketCount.load() == 1
  check gSetupInitializeBucketCount.load() == 1
  check pingBucketCtxs() == @[ctx]
  check destroyBucketCtxs() == @[ctx]
  check initializeBucketCtxs() == @[ctx]

suite "API library init":
  test "lib_createContext returns only after immediate requests and listener registration are ready":
    gSetupProvidersShouldFail.store(0)
    gReadyCallbackCount.store(0)
    gReadyCallbackValue.store(-1)

    let ctx = createContext()
    check ctx != 0'u32

    let handle = onReadyEvent(ctx, readyCallback)
    check handle > 0'u64

    let pingRes = ping_request_request(ctx)
    check pingRes.error_message.isNil()
    check pingRes.value == 99
    clearError(pingRes.error_message)

    let initializeRes = initialize_request_request(ctx)
    check initializeRes.error_message.isNil()
    check initializeRes.initialized == true
    clearError(initializeRes.error_message)

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
    check initializeBucketCtxs().len == 0

  test "shutdown removes registry entry and repeated create/shutdown cycles work":
    gSetupProvidersShouldFail.store(0)
    for _ in 0 ..< 3:
      resetSetupBucketState()
      let ctx = createContext()
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
        echo "initialize buckets: ", initializeBucketCtxs()
        echo "ping_request_request error: ", $pingRes.error_message
      check pingRes.error_message.isNil()
      check pingRes.value == 99
      clearError(pingRes.error_message)

      let destroyRes = destroy_request_request(ctx)
      if not destroyRes.error_message.isNil:
        echo "ping buckets: ", pingBucketCtxs()
        echo "destroy buckets: ", destroyBucketCtxs()
        echo "initialize buckets: ", initializeBucketCtxs()
        echo "destroy_request_request error: ", $destroyRes.error_message
      check destroyRes.error_message.isNil()
      check destroyRes.status == 0
      clearError(destroyRes.error_message)

      apitestlib_shutdown(ctx)

      withLock(gapitestlibCtxsLock):
        activeCtxCount = gapitestlibCtxs.len
      check activeCtxCount == 0

  test "two library instances coexist and remain independently usable":
    gSetupProvidersShouldFail.store(0)
    let ctx1 = createContext()
    let ctx2 = createContext()
    check ctx1 != 0'u32
    check ctx2 != 0'u32
    check ctx1 != ctx2

    var activeCtxCount = -1
    withLock(gapitestlibCtxsLock):
      activeCtxCount = gapitestlibCtxs.len
    check activeCtxCount == 2
    check pingBucketCtxs().sorted() == @[ctx1, ctx2].sorted()
    check destroyBucketCtxs().sorted() == @[ctx1, ctx2].sorted()
    check initializeBucketCtxs().sorted() == @[ctx1, ctx2].sorted()

    let pingRes1 = ping_request_request(ctx1)
    check pingRes1.error_message.isNil()
    check pingRes1.value == 99
    clearError(pingRes1.error_message)

    let pingRes2 = ping_request_request(ctx2)
    check pingRes2.error_message.isNil()
    check pingRes2.value == 99
    clearError(pingRes2.error_message)

    let initializeRes1 = initialize_request_request(ctx1)
    check initializeRes1.error_message.isNil()
    check initializeRes1.initialized == true
    clearError(initializeRes1.error_message)

    let initializeRes2 = initialize_request_request(ctx2)
    check initializeRes2.error_message.isNil()
    check initializeRes2.initialized == true
    clearError(initializeRes2.error_message)

    apitestlib_shutdown(ctx1)

    withLock(gapitestlibCtxsLock):
      activeCtxCount = gapitestlibCtxs.len
    check activeCtxCount == 1
    check pingBucketCtxs() == @[ctx2]
    check destroyBucketCtxs() == @[ctx2]
    check initializeBucketCtxs() == @[ctx2]

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
    check initializeBucketCtxs().len == 0

  test "repeated createContext shutdown sequences remain usable":
    gSetupProvidersShouldFail.store(0)
    for _ in 0 ..< 2:
      let ctx = createContext()
      check ctx != 0'u32

      let pingRes = ping_request_request(ctx)
      check pingRes.error_message.isNil()
      check pingRes.value == 99
      clearError(pingRes.error_message)

      let initializeRes = initialize_request_request(ctx)
      check initializeRes.error_message.isNil()
      check initializeRes.initialized == true
      clearError(initializeRes.error_message)

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
      check initializeBucketCtxs().len == 0

  test "createContext returns a generic startup error when setupProviders fails":
    gSetupProvidersShouldFail.store(1)

    var createContextRes = apitestlib_createContext()
    defer:
      freeCreateContextResult(createContextRes)
      gSetupProvidersShouldFail.store(0)

    check createContextRes.ctx == 0'u32
    check not createContextRes.error_message.isNil()
    check $createContextRes.error_message ==
      "Library context creation failed during request processing startup"
