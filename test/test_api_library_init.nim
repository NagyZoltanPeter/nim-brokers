import testutils/unittests
import chronos
import std/[algorithm, atomics, locks, os]

import brokers/[api_library, broker_context, event_broker, request_broker]

RequestBroker(API):
  type InitializeRequest = object
    initialized*: bool

  proc signature*(): Future[Result[InitializeRequest, string]] {.async.}

RequestBroker(API):
  type ShutdownRequest = object
    status*: int32

  proc signature*(): Future[Result[ShutdownRequest, string]] {.async.}

RequestBroker(API):
  type PingRequest = object
    value*: int32

  proc signature*(): Future[Result[PingRequest, string]] {.async.}

RequestBroker(API):
  type DualNamingRequest = object
    label*: string
    code*: int32

  proc signature*(): Future[Result[DualNamingRequest, string]] {.async.}
  proc signatureWithInput*(
    input: string
  ): Future[Result[DualNamingRequest, string]] {.async.}

EventBroker(API):
  type ReadyEvent = object
    value*: int32

var gLibCtx {.threadvar.}: BrokerContext
var gReadyCallbackCount: Atomic[int32]
var gReadyCallbackValue: Atomic[int32]
var gSetupProvidersCount: Atomic[int32]
var gSetupPingBucketCount: Atomic[int32]
var gSetupShutdownBucketCount: Atomic[int32]
var gSetupInitializeBucketCount: Atomic[int32]
var gSetupProvidersShouldFail: Atomic[int32]
var gShutdownRequestCount: Atomic[int32]

proc recordRequestBrokerBuckets() =
  withLock(gInitializeRequestMtLock):
    gSetupInitializeBucketCount.store(int32(gInitializeRequestMtBucketCount))
  withLock(gShutdownRequestMtLock):
    gSetupShutdownBucketCount.store(int32(gShutdownRequestMtBucketCount))
  withLock(gPingRequestMtLock):
    gSetupPingBucketCount.store(int32(gPingRequestMtBucketCount))

proc resetSetupBucketState() =
  gSetupPingBucketCount.store(-1)
  gSetupShutdownBucketCount.store(-1)
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

  let shutdownProviderRes = ShutdownRequest.setProvider(
    ctx,
    proc(): Future[Result[ShutdownRequest, string]] {.closure, async.} =
      discard gShutdownRequestCount.fetchAdd(1)
      return ok(ShutdownRequest(status: 0)),
  )
  if shutdownProviderRes.isErr():
    return
      err("failed to register ShutdownRequest provider: " & shutdownProviderRes.error())

  let pingProviderRes = PingRequest.setProvider(
    ctx,
    proc(): Future[Result[PingRequest, string]] {.closure, async.} =
      return ok(PingRequest(value: 99)),
  )
  if pingProviderRes.isErr():
    return err("failed to register PingRequest provider: " & pingProviderRes.error())

  let dualNamingProviderRes = DualNamingRequest.setProvider(
    ctx,
    proc(): Future[Result[DualNamingRequest, string]] {.closure, async.} =
      return ok(DualNamingRequest(label: "default", code: 1)),
  )
  if dualNamingProviderRes.isErr():
    return err(
      "failed to register DualNamingRequest zero-arg provider: " &
        dualNamingProviderRes.error()
    )

  let dualNamingWithInputProviderRes = DualNamingRequest.setProvider(
    ctx,
    proc(input: string): Future[Result[DualNamingRequest, string]] {.closure, async.} =
      return ok(DualNamingRequest(label: "input:" & input, code: int32(input.len))),
  )
  if dualNamingWithInputProviderRes.isErr():
    return err(
      "failed to register DualNamingRequest input provider: " &
        dualNamingWithInputProviderRes.error()
    )

  recordRequestBrokerBuckets()
  ok()

registerBrokerLibrary:
  name:
    "apitestlib"
  initializeRequest:
    InitializeRequest
  shutdownRequest:
    ShutdownRequest

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

proc shutdownBucketCtxs(): seq[uint32] =
  withLock(gShutdownRequestMtLock):
    for i in 0 ..< gShutdownRequestMtBucketCount:
      result.add(uint32(gShutdownRequestMtBuckets[i].brokerCtx))

proc initializeBucketCtxs(): seq[uint32] =
  withLock(gInitializeRequestMtLock):
    for i in 0 ..< gInitializeRequestMtBucketCount:
      result.add(uint32(gInitializeRequestMtBuckets[i].brokerCtx))

proc freeCreateContextResult(r: var apitestlibCreateContextResult) =
  free_apitestlib_create_context_result(addr r)

proc freeDualNamingResult(r: var DualNamingRequestCResult) =
  apitestlib_free_dual_naming_result(addr r)

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
  check gSetupShutdownBucketCount.load() == 1
  check gSetupInitializeBucketCount.load() == 1
  check pingBucketCtxs() == @[ctx]
  check shutdownBucketCtxs() == @[ctx]
  check initializeBucketCtxs() == @[ctx]

suite "API library init":
  test "lib_createContext returns only after immediate requests and listener registration are ready":
    gSetupProvidersShouldFail.store(0)
    gShutdownRequestCount.store(0)
    gReadyCallbackCount.store(0)
    gReadyCallbackValue.store(-1)

    let ctx = createContext()
    check ctx != 0'u32

    let handle = apitestlib_onReadyEvent(ctx, readyCallback)
    check handle > 0'u64

    let pingRes = apitestlib_ping(ctx)
    check pingRes.error_message.isNil()
    check pingRes.value == 99
    clearError(pingRes.error_message)

    let initializeRes = apitestlib_initialize(ctx)
    check initializeRes.error_message.isNil()
    check initializeRes.initialized == true
    clearError(initializeRes.error_message)

    var waitedMs = 0
    while gReadyCallbackCount.load() == 0 and waitedMs < 1000:
      sleep(10)
      waitedMs += 10

    check gReadyCallbackCount.load() >= 1
    check gReadyCallbackValue.load() == 7

    apitestlib_offReadyEvent(ctx, handle)

    apitestlib_shutdown(ctx)
    check gShutdownRequestCount.load() == 1

    var activeCtxCount = -1
    withLock(gapitestlibCtxsLock):
      activeCtxCount = gapitestlibCtxs.len
    check activeCtxCount == 0
    check pingBucketCtxs().len == 0
    check shutdownBucketCtxs().len == 0
    check initializeBucketCtxs().len == 0

  test "shutdown removes registry entry and repeated create/shutdown cycles work":
    gSetupProvidersShouldFail.store(0)
    gShutdownRequestCount.store(0)
    for _ in 0 ..< 3:
      resetSetupBucketState()
      let ctx = createContext()
      check ctx != 0'u32

      var activeCtxCount = -1
      withLock(gapitestlibCtxsLock):
        activeCtxCount = gapitestlibCtxs.len
      check activeCtxCount == 1
      assertSingleContextBuckets(ctx)

      let pingRes = apitestlib_ping(ctx)
      if not pingRes.error_message.isNil:
        echo "ping buckets: ", pingBucketCtxs()
        echo "shutdown buckets: ", shutdownBucketCtxs()
        echo "initialize buckets: ", initializeBucketCtxs()
        echo "apitestlib_ping error: ", $pingRes.error_message
      check pingRes.error_message.isNil()
      check pingRes.value == 99
      clearError(pingRes.error_message)

      let shutdownCountBefore = gShutdownRequestCount.load()
      apitestlib_shutdown(ctx)
      check gShutdownRequestCount.load() == shutdownCountBefore + 1

      withLock(gapitestlibCtxsLock):
        activeCtxCount = gapitestlibCtxs.len
      check activeCtxCount == 0

  test "two library instances coexist and remain independently usable":
    gSetupProvidersShouldFail.store(0)
    gShutdownRequestCount.store(0)
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
    check shutdownBucketCtxs().sorted() == @[ctx1, ctx2].sorted()
    check initializeBucketCtxs().sorted() == @[ctx1, ctx2].sorted()

    let pingRes1 = apitestlib_ping(ctx1)
    check pingRes1.error_message.isNil()
    check pingRes1.value == 99
    clearError(pingRes1.error_message)

    let pingRes2 = apitestlib_ping(ctx2)
    check pingRes2.error_message.isNil()
    check pingRes2.value == 99
    clearError(pingRes2.error_message)

    let initializeRes1 = apitestlib_initialize(ctx1)
    check initializeRes1.error_message.isNil()
    check initializeRes1.initialized == true
    clearError(initializeRes1.error_message)

    let initializeRes2 = apitestlib_initialize(ctx2)
    check initializeRes2.error_message.isNil()
    check initializeRes2.initialized == true
    clearError(initializeRes2.error_message)

    let shutdownCountBeforeCtx1 = gShutdownRequestCount.load()
    apitestlib_shutdown(ctx1)
    check gShutdownRequestCount.load() == shutdownCountBeforeCtx1 + 1

    withLock(gapitestlibCtxsLock):
      activeCtxCount = gapitestlibCtxs.len
    check activeCtxCount == 1
    check pingBucketCtxs() == @[ctx2]
    check shutdownBucketCtxs() == @[ctx2]
    check initializeBucketCtxs() == @[ctx2]

    let shutdownCountBeforeCtx2 = gShutdownRequestCount.load()
    apitestlib_shutdown(ctx2)
    check gShutdownRequestCount.load() == shutdownCountBeforeCtx2 + 1

    withLock(gapitestlibCtxsLock):
      activeCtxCount = gapitestlibCtxs.len
    check activeCtxCount == 0
    check pingBucketCtxs().len == 0
    check shutdownBucketCtxs().len == 0
    check initializeBucketCtxs().len == 0

  test "repeated createContext shutdown sequences remain usable":
    gSetupProvidersShouldFail.store(0)
    gShutdownRequestCount.store(0)
    for _ in 0 ..< 2:
      let ctx = createContext()
      check ctx != 0'u32

      let pingRes = apitestlib_ping(ctx)
      check pingRes.error_message.isNil()
      check pingRes.value == 99
      clearError(pingRes.error_message)

      let initializeRes = apitestlib_initialize(ctx)
      check initializeRes.error_message.isNil()
      check initializeRes.initialized == true
      clearError(initializeRes.error_message)

      let shutdownCountBefore = gShutdownRequestCount.load()
      apitestlib_shutdown(ctx)
      check gShutdownRequestCount.load() == shutdownCountBefore + 1

      var activeCtxCount = -1
      withLock(gapitestlibCtxsLock):
        activeCtxCount = gapitestlibCtxs.len
      check activeCtxCount == 0
      check pingBucketCtxs().len == 0
      check shutdownBucketCtxs().len == 0
      check initializeBucketCtxs().len == 0

  test "dual-signature request brokers expose distinct public C wrapper names":
    gSetupProvidersShouldFail.store(0)
    gShutdownRequestCount.store(0)

    let ctx = createContext()
    check ctx != 0'u32

    var zeroArgRes = apitestlib_dual_naming(ctx)
    defer:
      freeDualNamingResult(zeroArgRes)
    check zeroArgRes.error_message.isNil()
    check $zeroArgRes.label == "default"
    check zeroArgRes.code == 1

    var argRes = apitestlib_dual_naming_with_input(ctx, cstring("omega"))
    defer:
      freeDualNamingResult(argRes)
    check argRes.error_message.isNil()
    check $argRes.label == "input:omega"
    check argRes.code == 5

    let shutdownCountBefore = gShutdownRequestCount.load()
    apitestlib_shutdown(ctx)
    check gShutdownRequestCount.load() == shutdownCountBefore + 1

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
