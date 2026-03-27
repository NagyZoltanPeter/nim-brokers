## mylib_expanded.nim — Current macro expansion of examples/ffiapi/nimlib/mylib.nim
## =================================================================================
##
## Regenerated from the CURRENT examples/ffiapi/nimlib/mylib.nim by compiling with:
##
##   nim c -d:BrokerFfiApi -d:brokerDebug --threads:on --app:lib \
##     --nimMainPrefix:mylib --path:src \
##     --outdir:examples/ffiapi/nimlib/build examples/ffiapi/nimlib/mylib.nim
##
## and extracting the generated code from build/mylib_brokerdebug.txt.
##
## Notes:
## - NOT compilable as-is.
## - This version intentionally restores the previously omitted generated bodies.
## - Gensym suffixes are normal Nim macro hygiene artifacts.
## - The debug AST/treeRepr preamble is omitted, but the generated code itself is kept.
##
## Structure:
##   1. ApiType expansions: DeviceInfo, AddDeviceSpec
##   2. RequestBroker(API) expansions:
##      InitializeRequest, ShutdownRequest, AddDevice, RemoveDevice,
##      GetDevice, ListDevices
##   3. EventBroker(API) expansions, including shared RegisterEventListenerResult
##   4. registerBrokerLibrary expansion for "mylib"

##
## Readable companion:
## - Removes accidental brokerDebug treeRepr blocks (StmtList / mode markers).
## - Strips Nim hygiene suffixes like `gensym42 from local identifiers.
## - Renames obvious generated locals like provider_587202969 to provider.
## - Collapses exact duplicated section prefixes when the API expansion embeds the same MT/runtime block twice.
## - Keeps generated structure intact; this is still reference material, not hand-maintained code.

# ===== ApiType: DeviceInfo / AddDeviceSpec =====
## Flow:
## - These are the FFI-safe data carriers shared by request and event exports.
## - Each ApiType generates a Nim object, a C ABI mirror type, and encode helpers.
type
  DeviceInfo* = object
    deviceId*: int64
    name*: string
    deviceType*: string
    address*: string
    online*: bool
type
  DeviceInfoCItem* {.exportc.} = object
    deviceId*: int64
    name*: cstring
    deviceType*: cstring
    address*: cstring
    online*: bool
proc encodeDeviceInfoToCItem*(item: DeviceInfo): DeviceInfoCItem =
  result.deviceId = item.deviceId
  result.name = allocCStringCopy(item.name)
  result.deviceType = allocCStringCopy(item.deviceType)
  result.address = allocCStringCopy(item.address)
  result.online = item.online

type
  AddDeviceSpec* = object
    name*: string
    deviceType*: string
    address*: string
# ===== RequestBroker(API): InitializeRequest =====
## Flow:
## - The first generated block is the multithreaded broker runtime for this request type.
## - `setProvider` binds the provider to a broker context and thread, then installs an AsyncChannel loop.
## - `request` calls the provider directly on the same thread or sends a cross-thread message and waits for the reply.
## - The API tail encodes the Nim result into the exported C result struct.
## Collapsed identical repeated expansion block.
## The removed copy was byte-for-byte identical to the first generated MT/runtime block.

type
  InitializeRequest* = object
    configPath*: string
    initialized*: bool
  InitializeRequestProviderWithArgs = proc (configPath: string): Future[
      Result[InitializeRequest, string]] {.async.}
  InitializeRequestMtRequestMsg = object
    isShutdown: bool
    requestKind: int
    configPath: string
    responseChan: ptr AsyncChannel[Result[InitializeRequest, string]]
  InitializeRequestMtBucket = object
    brokerCtx: BrokerContext
    requestChan: ptr AsyncChannel[InitializeRequestMtRequestMsg]
    threadId: pointer
    threadGen: uint64
var gInitializeRequestMtBuckets: ptr UncheckedArray[InitializeRequestMtBucket]
var gInitializeRequestMtBucketCount: int
var gInitializeRequestMtBucketCap: int
var gInitializeRequestMtLock: Lock
var gInitializeRequestMtInit: Atomic[int] ## 0 = uninitialised, 1 = initialising, 2 = ready.
                                          ## CAS(0→1) wins the race; losers spin until 2.
proc ensureInitInitializeRequestMtBroker() =
  if gInitializeRequestMtInit.load(moRelaxed) == 2:
    return
  var expected = 0
  if gInitializeRequestMtInit.compareExchange(expected, 1, moAcquire,
      moRelaxed):
    initLock(gInitializeRequestMtLock)
    gInitializeRequestMtBucketCap = 4
    gInitializeRequestMtBuckets = cast[ptr UncheckedArray[
        InitializeRequestMtBucket]](createShared(InitializeRequestMtBucket,
        gInitializeRequestMtBucketCap))
    gInitializeRequestMtBucketCount = 0
    gInitializeRequestMtInit.store(2, moRelease)
  else:
    while gInitializeRequestMtInit.load(moAcquire) != 2:
      discard

proc growInitializeRequestMtBuckets() =
  ## Must be called under lock.
  let newCap = gInitializeRequestMtBucketCap * 2
  let newBuf = cast[ptr UncheckedArray[InitializeRequestMtBucket]](createShared(
      InitializeRequestMtBucket, newCap))
  for i in 0 ..< gInitializeRequestMtBucketCount:
    newBuf[i] = gInitializeRequestMtBuckets[i]
  deallocShared(gInitializeRequestMtBuckets)
  gInitializeRequestMtBuckets = newBuf
  gInitializeRequestMtBucketCap = newCap

var gInitializeRequestMtRequestTimeout*: Duration = seconds(5) ## Default timeout for cross-thread requests. Same-thread requests
                                                               ## bypass this (they call the provider directly).
                                                               ## NOTE: Set during initialization before spawning worker threads.
                                                               ## Reading from multiple threads is safe on x86-64 (aligned int64),
                                                               ## but concurrent writes are not guaranteed atomic on all platforms.
proc setRequestTimeout*(_: typedesc[InitializeRequest];
                        timeout: Duration) =
  ## Set the cross-thread request timeout for this broker type.
  ## Call this during initialization before spawning worker threads.
  gInitializeRequestMtRequestTimeout = timeout

proc requestTimeout*(_: typedesc[InitializeRequest]): Duration =
  ## Get the current cross-thread request timeout for this broker type.
  gInitializeRequestMtRequestTimeout

var gInitializeRequestTvWithArgCtxs {.threadvar.}: seq[BrokerContext]
var gInitializeRequestTvWithArgHandlers {.threadvar.}: seq[
    InitializeRequestProviderWithArgs]
proc processLoopInitializeRequest(requestChan: ptr AsyncChannel[
    InitializeRequestMtRequestMsg]; loopCtx: BrokerContext) {.
    async: (raises: []).} =
  while true:
    let recvRes = catch do:
      await requestChan.recv()
    if recvRes.isErr():
      break
    let msg = recvRes.get()
    if msg.isShutdown:
      break
    if msg.requestKind == 1:
      var handler1: InitializeRequestProviderWithArgs
      for i in 0 ..< gInitializeRequestTvWithArgCtxs.len:
        if gInitializeRequestTvWithArgCtxs[i] == loopCtx:
          handler1 = gInitializeRequestTvWithArgHandlers[i]
          break
      if handler1.isNil():
        msg.responseChan[].sendSync(err(Result[InitializeRequest, string], "RequestBroker(" &
            "InitializeRequest" &
            "): no provider registered for input signature"))
      else:
        let catchedRes = catch do:
          await handler1(msg.configPath)
        if catchedRes.isErr():
          msg.responseChan[].sendSync(err(Result[InitializeRequest, string], "RequestBroker(" &
              "InitializeRequest" &
              "): provider threw exception: " &
              catchedRes.error.msg))
        else:
          let providerRes = catchedRes.get()
          if providerRes.isOk():
            let resultValue = providerRes.get()
            when compiles(resultValue.isNil()):
              if resultValue.isNil():
                msg.responseChan[].sendSync(err(
                    Result[InitializeRequest, string], "RequestBroker(" &
                    "InitializeRequest" &
                    "): provider returned nil result"))
                continue
          msg.responseChan[].sendSync(providerRes)

proc setProvider*(_: typedesc[InitializeRequest];
                  handler: InitializeRequestProviderWithArgs): Result[
    void, string] =
  ensureInitInitializeRequestMtBroker()
  let myThreadGen = currentMtThreadGen()
  for i in 0 ..< gInitializeRequestTvWithArgCtxs.len:
    if gInitializeRequestTvWithArgCtxs[i] == DefaultBrokerContext:
      var isStale = true
      withLock(gInitializeRequestMtLock):
        for j in 0 ..< gInitializeRequestMtBucketCount:
          if gInitializeRequestMtBuckets[j].brokerCtx ==
              DefaultBrokerContext and
              gInitializeRequestMtBuckets[j].threadId ==
              currentMtThreadId() and
              gInitializeRequestMtBuckets[j].threadGen ==
              myThreadGen:
            isStale = false
            break
      if isStale:
        gInitializeRequestTvWithArgCtxs.del(i)
        gInitializeRequestTvWithArgHandlers.del(i)
        break
      else:
        return err("Provider already set")
  gInitializeRequestTvWithArgCtxs.add(DefaultBrokerContext)
  gInitializeRequestTvWithArgHandlers.add(handler)
  var spawnChan: ptr AsyncChannel[InitializeRequestMtRequestMsg]
  withLock(gInitializeRequestMtLock):
    for i in 0 ..< gInitializeRequestMtBucketCount:
      if gInitializeRequestMtBuckets[i].brokerCtx ==
          DefaultBrokerContext:
        if gInitializeRequestMtBuckets[i].threadId ==
            currentMtThreadId() and
            gInitializeRequestMtBuckets[i].threadGen ==
            myThreadGen:
          return ok()
        else:
          gInitializeRequestTvWithArgCtxs.setLen(
              gInitializeRequestTvWithArgCtxs.len - 1)
          gInitializeRequestTvWithArgHandlers.setLen(
              gInitializeRequestTvWithArgHandlers.len - 1)
          return err("RequestBroker(" & "InitializeRequest" &
              "): provider already set from another thread")
    if gInitializeRequestMtBucketCount >= gInitializeRequestMtBucketCap:
      growInitializeRequestMtBuckets()
    spawnChan = cast[ptr AsyncChannel[InitializeRequestMtRequestMsg]](createShared(
        AsyncChannel[InitializeRequestMtRequestMsg], 1))
    discard spawnChan[].open()
    let idx = gInitializeRequestMtBucketCount
    gInitializeRequestMtBuckets[idx] = InitializeRequestMtBucket(
        brokerCtx: DefaultBrokerContext, requestChan: spawnChan,
        threadId: currentMtThreadId(), threadGen: myThreadGen)
    gInitializeRequestMtBucketCount += 1
  if not spawnChan.isNil:
    asyncSpawn processLoopInitializeRequest(spawnChan,
        DefaultBrokerContext)
  return ok()

proc setProvider*(_: typedesc[InitializeRequest];
                  brokerCtx: BrokerContext;
                  handler: InitializeRequestProviderWithArgs): Result[
    void, string] =
  if brokerCtx == DefaultBrokerContext:
    return setProvider(InitializeRequest, handler)
  ensureInitInitializeRequestMtBroker()
  let myThreadGen = currentMtThreadGen()
  for i in 0 ..< gInitializeRequestTvWithArgCtxs.len:
    if gInitializeRequestTvWithArgCtxs[i] == brokerCtx:
      var isStale = true
      withLock(gInitializeRequestMtLock):
        for j in 0 ..< gInitializeRequestMtBucketCount:
          if gInitializeRequestMtBuckets[j].brokerCtx ==
              brokerCtx and
              gInitializeRequestMtBuckets[j].threadId ==
              currentMtThreadId() and
              gInitializeRequestMtBuckets[j].threadGen ==
              myThreadGen:
            isStale = false
            break
      if isStale:
        gInitializeRequestTvWithArgCtxs.del(i)
        gInitializeRequestTvWithArgHandlers.del(i)
        break
      else:
        return err("RequestBroker(" & "InitializeRequest" &
            "): provider already set for broker context " &
            $brokerCtx)
  gInitializeRequestTvWithArgCtxs.add(brokerCtx)
  gInitializeRequestTvWithArgHandlers.add(handler)
  var spawnChan: ptr AsyncChannel[InitializeRequestMtRequestMsg]
  withLock(gInitializeRequestMtLock):
    for i in 0 ..< gInitializeRequestMtBucketCount:
      if gInitializeRequestMtBuckets[i].brokerCtx ==
          brokerCtx:
        if gInitializeRequestMtBuckets[i].threadId ==
            currentMtThreadId() and
            gInitializeRequestMtBuckets[i].threadGen ==
            myThreadGen:
          return ok()
        else:
          gInitializeRequestTvWithArgCtxs.setLen(
              gInitializeRequestTvWithArgCtxs.len - 1)
          gInitializeRequestTvWithArgHandlers.setLen(
              gInitializeRequestTvWithArgHandlers.len - 1)
          return err("RequestBroker(" & "InitializeRequest" &
              "): provider already set from another thread for context " &
              $brokerCtx)
    if gInitializeRequestMtBucketCount >= gInitializeRequestMtBucketCap:
      growInitializeRequestMtBuckets()
    spawnChan = cast[ptr AsyncChannel[InitializeRequestMtRequestMsg]](createShared(
        AsyncChannel[InitializeRequestMtRequestMsg], 1))
    discard spawnChan[].open()
    let idx = gInitializeRequestMtBucketCount
    gInitializeRequestMtBuckets[idx] = InitializeRequestMtBucket(
        brokerCtx: brokerCtx, requestChan: spawnChan,
        threadId: currentMtThreadId(), threadGen: myThreadGen)
    gInitializeRequestMtBucketCount += 1
  if not spawnChan.isNil:
    asyncSpawn processLoopInitializeRequest(spawnChan,
        brokerCtx)
  return ok()

proc request*(_: typedesc[InitializeRequest]): Future[
    Result[InitializeRequest, string]] {.async: (raises: []).} =
  return err("RequestBroker(" & "InitializeRequest" &
      "): no zero-arg provider registered")

proc request*(_: typedesc[InitializeRequest]; configPath: string): Future[
    Result[InitializeRequest, string]] {.async: (raises: []).} =
  return await request(InitializeRequest, DefaultBrokerContext, configPath)

proc request*(_: typedesc[InitializeRequest]; brokerCtx: BrokerContext;
              configPath: string): Future[Result[InitializeRequest, string]] {.
    async: (raises: []).} =
  ensureInitInitializeRequestMtBroker()
  var reqChan: ptr AsyncChannel[InitializeRequestMtRequestMsg]
  var sameThread = false
  let myThreadGen = currentMtThreadGen()
  withLock(gInitializeRequestMtLock):
    for i in 0 ..< gInitializeRequestMtBucketCount:
      if gInitializeRequestMtBuckets[i].brokerCtx == brokerCtx:
        if gInitializeRequestMtBuckets[i].threadId ==
            currentMtThreadId() and
            gInitializeRequestMtBuckets[i].threadGen ==
            myThreadGen:
          sameThread = true
        else:
          reqChan = gInitializeRequestMtBuckets[i].requestChan
        break
  if sameThread:
    var provider: InitializeRequestProviderWithArgs
    for i in 0 ..< gInitializeRequestTvWithArgCtxs.len:
      if gInitializeRequestTvWithArgCtxs[i] == brokerCtx:
        provider = gInitializeRequestTvWithArgHandlers[i]
        break
    if provider.isNil():
      return err("RequestBroker(" & "InitializeRequest" &
          "): no provider registered for input signature")
    let catchedRes = catch do:
      await provider(configPath)
    if catchedRes.isErr():
      return err("RequestBroker(" & "InitializeRequest" &
          "): provider threw exception: " &
          catchedRes.error.msg)
    let providerRes = catchedRes.get()
    if providerRes.isOk():
      let resultValue = providerRes.get()
      when compiles(resultValue.isNil()):
        if resultValue.isNil():
          return err("RequestBroker(" & "InitializeRequest" &
              "): provider returned nil result")
    return providerRes
  else:
    if reqChan.isNil():
      return err("RequestBroker(" & "InitializeRequest" &
          "): no provider registered for broker context " &
          $brokerCtx)
    let respChan = cast[ptr AsyncChannel[Result[InitializeRequest, string]]](createShared(
        AsyncChannel[Result[InitializeRequest, string]], 1))
    discard respChan[].open()
    var msg = InitializeRequestMtRequestMsg(isShutdown: false,
        requestKind: 1, configPath: configPath, responseChan: respChan)
    reqChan[].sendSync(msg)
    let recvFut = respChan.recv()
    let completedRes = catch do:
      await withTimeout(recvFut, gInitializeRequestMtRequestTimeout)
    if completedRes.isErr():
      return err("RequestBroker(" & "InitializeRequest" & "): recv failed: " &
          completedRes.error.msg)
    if not completedRes.get():
      return err("RequestBroker(" & "InitializeRequest" &
          "): cross-thread request timed out after " &
          $gInitializeRequestMtRequestTimeout)
    respChan[].close()
    deallocShared(respChan)
    let recvRes = catch do:
      recvFut.read()
    if recvRes.isErr():
      return err("RequestBroker(" & "InitializeRequest" & "): recv failed: " &
          recvRes.error.msg)
    return recvRes.get()

proc clearProvider*(_: typedesc[InitializeRequest]; brokerCtx: BrokerContext) =
  ensureInitInitializeRequestMtBroker()
  var reqChan: ptr AsyncChannel[InitializeRequestMtRequestMsg]
  var isProviderThread = false
  let myThreadGen = currentMtThreadGen()
  withLock(gInitializeRequestMtLock):
    var foundIdx = -1
    for i in 0 ..< gInitializeRequestMtBucketCount:
      if gInitializeRequestMtBuckets[i].brokerCtx == brokerCtx:
        reqChan = gInitializeRequestMtBuckets[i].requestChan
        isProviderThread = (gInitializeRequestMtBuckets[i].threadId ==
            currentMtThreadId() and
            gInitializeRequestMtBuckets[i].threadGen ==
            myThreadGen)
        foundIdx = i
        break
    if foundIdx >= 0:
      for i in foundIdx ..<
          gInitializeRequestMtBucketCount - 1:
        gInitializeRequestMtBuckets[i] = gInitializeRequestMtBuckets[
            i + 1]
      gInitializeRequestMtBucketCount -= 1
  if isProviderThread:
    for i in countdown(gInitializeRequestTvWithArgCtxs.len - 1, 0):
      if gInitializeRequestTvWithArgCtxs[i] == brokerCtx:
        gInitializeRequestTvWithArgCtxs.del(i)
        gInitializeRequestTvWithArgHandlers.del(i)
        break
  elif not reqChan.isNil():
    trace "clearProvider called from non-provider thread; " &
        "threadvar entries on provider thread are stale but harmless " &
        "(next setProvider will detect and clean them)",
          brokerType = "InitializeRequest"
  if not reqChan.isNil():
    var shutdownMsg = InitializeRequestMtRequestMsg(isShutdown: true)
    reqChan[].sendSync(shutdownMsg)

proc clearProvider*(_: typedesc[InitializeRequest]) =
  clearProvider(InitializeRequest, DefaultBrokerContext)

proc cleanupApiRequestProvider_InitializeRequest(ctx: BrokerContext) =
  InitializeRequest.clearProvider(ctx)

type
  InitializeRequestCResult* {.exportc.} = object
    error_message*: cstring
    configPath*: cstring
    initialized*: bool
proc encodeInitializeRequestToC(obj: InitializeRequest): InitializeRequestCResult =
  result.configPath = allocCStringCopy(obj.configPath)
  result.initialized = obj.initialized

proc free_initialize_result(r: ptr InitializeRequestCResult) {.
    exportc: "free_initialize_result", cdecl, dynlib.} =
  if r.isNil:
    return
  if not r.error_message.isNil:
    freeCString(r.error_message)
  if not r.configPath.isNil:
    freeCString(r.configPath)

proc initialize*(ctx: uint32; configPath: cstring): InitializeRequestCResult {.
    exportc: "initialize", cdecl, dynlib.} =
  let brokerCtx = BrokerContext(ctx)
  let nim_configPath = $configPath
  let res = waitFor request(InitializeRequest, brokerCtx,
                                     nim_configPath)
  if res.isOk():
    return encodeInitializeRequestToC(res.get())
  else:
    var errResult: InitializeRequestCResult
    errResult.error_message = allocCStringCopy(res.error())
    return errResult
# ===== RequestBroker(API): ShutdownRequest =====
## Flow:
## - Same runtime pattern as InitializeRequest, but for a zero-argument shutdown request.
## - The exported C wrapper is intentionally internal-facing glue for library shutdown sequencing.
## Collapsed identical repeated expansion block.
## The removed copy was byte-for-byte identical to the first generated MT/runtime block.

type
  ShutdownRequest* = object
    status*: int32
  ShutdownRequestProviderNoArgs = proc (): Future[
      Result[ShutdownRequest, string]] {.async.}
  ShutdownRequestMtRequestMsg = object
    isShutdown: bool
    requestKind: int
    responseChan: ptr AsyncChannel[Result[ShutdownRequest, string]]
  ShutdownRequestMtBucket = object
    brokerCtx: BrokerContext
    requestChan: ptr AsyncChannel[ShutdownRequestMtRequestMsg]
    threadId: pointer
    threadGen: uint64
var gShutdownRequestMtBuckets: ptr UncheckedArray[ShutdownRequestMtBucket]
var gShutdownRequestMtBucketCount: int
var gShutdownRequestMtBucketCap: int
var gShutdownRequestMtLock: Lock
var gShutdownRequestMtInit: Atomic[int] ## 0 = uninitialised, 1 = initialising, 2 = ready.
                                        ## CAS(0→1) wins the race; losers spin until 2.
proc ensureInitShutdownRequestMtBroker() =
  if gShutdownRequestMtInit.load(moRelaxed) == 2:
    return
  var expected = 0
  if gShutdownRequestMtInit.compareExchange(expected, 1, moAcquire,
      moRelaxed):
    initLock(gShutdownRequestMtLock)
    gShutdownRequestMtBucketCap = 4
    gShutdownRequestMtBuckets = cast[ptr UncheckedArray[ShutdownRequestMtBucket]](createShared(
        ShutdownRequestMtBucket, gShutdownRequestMtBucketCap))
    gShutdownRequestMtBucketCount = 0
    gShutdownRequestMtInit.store(2, moRelease)
  else:
    while gShutdownRequestMtInit.load(moAcquire) != 2:
      discard

proc growShutdownRequestMtBuckets() =
  ## Must be called under lock.
  let newCap = gShutdownRequestMtBucketCap * 2
  let newBuf = cast[ptr UncheckedArray[ShutdownRequestMtBucket]](createShared(
      ShutdownRequestMtBucket, newCap))
  for i in 0 ..< gShutdownRequestMtBucketCount:
    newBuf[i] = gShutdownRequestMtBuckets[i]
  deallocShared(gShutdownRequestMtBuckets)
  gShutdownRequestMtBuckets = newBuf
  gShutdownRequestMtBucketCap = newCap

var gShutdownRequestMtRequestTimeout*: Duration = seconds(5) ## Default timeout for cross-thread requests. Same-thread requests
                                                             ## bypass this (they call the provider directly).
                                                             ## NOTE: Set during initialization before spawning worker threads.
                                                             ## Reading from multiple threads is safe on x86-64 (aligned int64),
                                                             ## but concurrent writes are not guaranteed atomic on all platforms.
proc setRequestTimeout*(_: typedesc[ShutdownRequest];
                        timeout: Duration) =
  ## Set the cross-thread request timeout for this broker type.
  ## Call this during initialization before spawning worker threads.
  gShutdownRequestMtRequestTimeout = timeout

proc requestTimeout*(_: typedesc[ShutdownRequest]): Duration =
  ## Get the current cross-thread request timeout for this broker type.
  gShutdownRequestMtRequestTimeout

var gShutdownRequestTvNoArgCtxs {.threadvar.}: seq[BrokerContext]
var gShutdownRequestTvNoArgHandlers {.threadvar.}: seq[
    ShutdownRequestProviderNoArgs]
proc processLoopShutdownRequest(requestChan: ptr AsyncChannel[
    ShutdownRequestMtRequestMsg]; loopCtx: BrokerContext) {.async: (raises: []).} =
  while true:
    let recvRes = catch do:
      await requestChan.recv()
    if recvRes.isErr():
      break
    let msg = recvRes.get()
    if msg.isShutdown:
      break
    if msg.requestKind == 0:
      var handler0: ShutdownRequestProviderNoArgs
      for i in 0 ..< gShutdownRequestTvNoArgCtxs.len:
        if gShutdownRequestTvNoArgCtxs[i] == loopCtx:
          handler0 = gShutdownRequestTvNoArgHandlers[i]
          break
      if handler0.isNil():
        msg.responseChan[].sendSync(err(Result[ShutdownRequest, string], "RequestBroker(" &
            "ShutdownRequest" &
            "): no zero-arg provider registered"))
      else:
        let catchedRes = catch do:
          await handler0()
        if catchedRes.isErr():
          msg.responseChan[].sendSync(err(Result[ShutdownRequest, string], "RequestBroker(" &
              "ShutdownRequest" &
              "): provider threw exception: " &
              catchedRes.error.msg))
        else:
          let providerRes = catchedRes.get()
          if providerRes.isOk():
            let resultValue = providerRes.get()
            when compiles(resultValue.isNil()):
              if resultValue.isNil():
                msg.responseChan[].sendSync(err(
                    Result[ShutdownRequest, string], "RequestBroker(" &
                    "ShutdownRequest" &
                    "): provider returned nil result"))
                continue
          msg.responseChan[].sendSync(providerRes)

proc setProvider*(_: typedesc[ShutdownRequest];
                  handler: ShutdownRequestProviderNoArgs): Result[
    void, string] =
  ensureInitShutdownRequestMtBroker()
  let myThreadGen = currentMtThreadGen()
  for i in 0 ..< gShutdownRequestTvNoArgCtxs.len:
    if gShutdownRequestTvNoArgCtxs[i] == DefaultBrokerContext:
      var isStale = true
      withLock(gShutdownRequestMtLock):
        for j in 0 ..< gShutdownRequestMtBucketCount:
          if gShutdownRequestMtBuckets[j].brokerCtx ==
              DefaultBrokerContext and
              gShutdownRequestMtBuckets[j].threadId ==
              currentMtThreadId() and
              gShutdownRequestMtBuckets[j].threadGen ==
              myThreadGen:
            isStale = false
            break
      if isStale:
        gShutdownRequestTvNoArgCtxs.del(i)
        gShutdownRequestTvNoArgHandlers.del(i)
        break
      else:
        return err("Zero-arg provider already set")
  gShutdownRequestTvNoArgCtxs.add(DefaultBrokerContext)
  gShutdownRequestTvNoArgHandlers.add(handler)
  var spawnChan: ptr AsyncChannel[ShutdownRequestMtRequestMsg]
  withLock(gShutdownRequestMtLock):
    for i in 0 ..< gShutdownRequestMtBucketCount:
      if gShutdownRequestMtBuckets[i].brokerCtx ==
          DefaultBrokerContext:
        if gShutdownRequestMtBuckets[i].threadId ==
            currentMtThreadId() and
            gShutdownRequestMtBuckets[i].threadGen ==
            myThreadGen:
          return ok()
        else:
          gShutdownRequestTvNoArgCtxs.setLen(gShutdownRequestTvNoArgCtxs.len - 1)
          gShutdownRequestTvNoArgHandlers.setLen(
              gShutdownRequestTvNoArgHandlers.len - 1)
          return err("RequestBroker(" & "ShutdownRequest" &
              "): provider already set from another thread")
    if gShutdownRequestMtBucketCount >= gShutdownRequestMtBucketCap:
      growShutdownRequestMtBuckets()
    spawnChan = cast[ptr AsyncChannel[ShutdownRequestMtRequestMsg]](createShared(
        AsyncChannel[ShutdownRequestMtRequestMsg], 1))
    discard spawnChan[].open()
    let idx = gShutdownRequestMtBucketCount
    gShutdownRequestMtBuckets[idx] = ShutdownRequestMtBucket(
        brokerCtx: DefaultBrokerContext, requestChan: spawnChan,
        threadId: currentMtThreadId(), threadGen: myThreadGen)
    gShutdownRequestMtBucketCount += 1
  asyncSpawn processLoopShutdownRequest(spawnChan,
                                        DefaultBrokerContext)
  return ok()

proc setProvider*(_: typedesc[ShutdownRequest];
                  brokerCtx: BrokerContext;
                  handler: ShutdownRequestProviderNoArgs): Result[
    void, string] =
  if brokerCtx == DefaultBrokerContext:
    return setProvider(ShutdownRequest, handler)
  ensureInitShutdownRequestMtBroker()
  let myThreadGen = currentMtThreadGen()
  for i in 0 ..< gShutdownRequestTvNoArgCtxs.len:
    if gShutdownRequestTvNoArgCtxs[i] == brokerCtx:
      var isStale = true
      withLock(gShutdownRequestMtLock):
        for j in 0 ..< gShutdownRequestMtBucketCount:
          if gShutdownRequestMtBuckets[j].brokerCtx ==
              brokerCtx and
              gShutdownRequestMtBuckets[j].threadId ==
              currentMtThreadId() and
              gShutdownRequestMtBuckets[j].threadGen ==
              myThreadGen:
            isStale = false
            break
      if isStale:
        gShutdownRequestTvNoArgCtxs.del(i)
        gShutdownRequestTvNoArgHandlers.del(i)
        break
      else:
        return err("RequestBroker(" & "ShutdownRequest" &
            "): zero-arg provider already set for broker context " &
            $brokerCtx)
  gShutdownRequestTvNoArgCtxs.add(brokerCtx)
  gShutdownRequestTvNoArgHandlers.add(handler)
  var spawnChan: ptr AsyncChannel[ShutdownRequestMtRequestMsg]
  withLock(gShutdownRequestMtLock):
    for i in 0 ..< gShutdownRequestMtBucketCount:
      if gShutdownRequestMtBuckets[i].brokerCtx ==
          brokerCtx:
        if gShutdownRequestMtBuckets[i].threadId ==
            currentMtThreadId() and
            gShutdownRequestMtBuckets[i].threadGen ==
            myThreadGen:
          return ok()
        else:
          gShutdownRequestTvNoArgCtxs.setLen(gShutdownRequestTvNoArgCtxs.len - 1)
          gShutdownRequestTvNoArgHandlers.setLen(
              gShutdownRequestTvNoArgHandlers.len - 1)
          return err("RequestBroker(" & "ShutdownRequest" &
              "): provider already set from another thread for context " &
              $brokerCtx)
    if gShutdownRequestMtBucketCount >= gShutdownRequestMtBucketCap:
      growShutdownRequestMtBuckets()
    spawnChan = cast[ptr AsyncChannel[ShutdownRequestMtRequestMsg]](createShared(
        AsyncChannel[ShutdownRequestMtRequestMsg], 1))
    discard spawnChan[].open()
    let idx = gShutdownRequestMtBucketCount
    gShutdownRequestMtBuckets[idx] = ShutdownRequestMtBucket(
        brokerCtx: brokerCtx, requestChan: spawnChan,
        threadId: currentMtThreadId(), threadGen: myThreadGen)
    gShutdownRequestMtBucketCount += 1
  asyncSpawn processLoopShutdownRequest(spawnChan, brokerCtx)
  return ok()

proc request*(_: typedesc[ShutdownRequest]): Future[
    Result[ShutdownRequest, string]] {.async: (raises: []).} =
  return await request(ShutdownRequest, DefaultBrokerContext)

proc request*(_: typedesc[ShutdownRequest]; brokerCtx: BrokerContext): Future[
    Result[ShutdownRequest, string]] {.async: (raises: []).} =
  ensureInitShutdownRequestMtBroker()
  var reqChan: ptr AsyncChannel[ShutdownRequestMtRequestMsg]
  var sameThread = false
  let myThreadGen = currentMtThreadGen()
  withLock(gShutdownRequestMtLock):
    for i in 0 ..< gShutdownRequestMtBucketCount:
      if gShutdownRequestMtBuckets[i].brokerCtx ==
          brokerCtx:
        if gShutdownRequestMtBuckets[i].threadId ==
            currentMtThreadId() and
            gShutdownRequestMtBuckets[i].threadGen ==
            myThreadGen:
          sameThread = true
        else:
          reqChan = gShutdownRequestMtBuckets[i].requestChan
        break
  if sameThread:
    var provider: ShutdownRequestProviderNoArgs
    for i in 0 ..< gShutdownRequestTvNoArgCtxs.len:
      if gShutdownRequestTvNoArgCtxs[i] == brokerCtx:
        provider = gShutdownRequestTvNoArgHandlers[i]
        break
    if provider.isNil():
      return err("RequestBroker(" & "ShutdownRequest" &
          "): no zero-arg provider registered")
    let catchedRes = catch do:
      await provider()
    if catchedRes.isErr():
      return err("RequestBroker(" & "ShutdownRequest" &
          "): provider threw exception: " &
          catchedRes.error.msg)
    let providerRes = catchedRes.get()
    if providerRes.isOk():
      let resultValue = providerRes.get()
      when compiles(resultValue.isNil()):
        if resultValue.isNil():
          return err("RequestBroker(" & "ShutdownRequest" &
              "): provider returned nil result")
    return providerRes
  else:
    if reqChan.isNil():
      return err("RequestBroker(" & "ShutdownRequest" &
          "): no zero-arg provider registered for broker context " &
          $brokerCtx)
    let respChan = cast[ptr AsyncChannel[
        Result[ShutdownRequest, string]]](createShared(
        AsyncChannel[Result[ShutdownRequest, string]], 1))
    discard respChan[].open()
    var msg = ShutdownRequestMtRequestMsg(isShutdown: false,
        requestKind: 0, responseChan: respChan)
    reqChan[].sendSync(msg)
    let recvFut = respChan.recv()
    let completedRes = catch do:
      await withTimeout(recvFut, gShutdownRequestMtRequestTimeout)
    if completedRes.isErr():
      return err("RequestBroker(" & "ShutdownRequest" & "): recv failed: " &
          completedRes.error.msg)
    if not completedRes.get():
      return err("RequestBroker(" & "ShutdownRequest" &
          "): cross-thread request timed out after " &
          $gShutdownRequestMtRequestTimeout)
    respChan[].close()
    deallocShared(respChan)
    let recvRes = catch do:
      recvFut.read()
    if recvRes.isErr():
      return err("RequestBroker(" & "ShutdownRequest" & "): recv failed: " &
          recvRes.error.msg)
    return recvRes.get()

proc clearProvider*(_: typedesc[ShutdownRequest]; brokerCtx: BrokerContext) =
  ensureInitShutdownRequestMtBroker()
  var reqChan: ptr AsyncChannel[ShutdownRequestMtRequestMsg]
  var isProviderThread = false
  let myThreadGen = currentMtThreadGen()
  withLock(gShutdownRequestMtLock):
    var foundIdx = -1
    for i in 0 ..< gShutdownRequestMtBucketCount:
      if gShutdownRequestMtBuckets[i].brokerCtx == brokerCtx:
        reqChan = gShutdownRequestMtBuckets[i].requestChan
        isProviderThread = (gShutdownRequestMtBuckets[i].threadId ==
            currentMtThreadId() and
            gShutdownRequestMtBuckets[i].threadGen ==
            myThreadGen)
        foundIdx = i
        break
    if foundIdx >= 0:
      for i in foundIdx ..<
          gShutdownRequestMtBucketCount - 1:
        gShutdownRequestMtBuckets[i] = gShutdownRequestMtBuckets[
            i + 1]
      gShutdownRequestMtBucketCount -= 1
  if isProviderThread:
    for i in countdown(gShutdownRequestTvNoArgCtxs.len - 1, 0):
      if gShutdownRequestTvNoArgCtxs[i] == brokerCtx:
        gShutdownRequestTvNoArgCtxs.del(i)
        gShutdownRequestTvNoArgHandlers.del(i)
        break
  elif not reqChan.isNil():
    trace "clearProvider called from non-provider thread; " &
        "threadvar entries on provider thread are stale but harmless " &
        "(next setProvider will detect and clean them)",
          brokerType = "ShutdownRequest"
  if not reqChan.isNil():
    var shutdownMsg = ShutdownRequestMtRequestMsg(isShutdown: true)
    reqChan[].sendSync(shutdownMsg)

proc clearProvider*(_: typedesc[ShutdownRequest]) =
  clearProvider(ShutdownRequest, DefaultBrokerContext)

proc cleanupApiRequestProvider_ShutdownRequest(ctx: BrokerContext) =
  ShutdownRequest.clearProvider(ctx)

type
  ShutdownRequestCResult* {.exportc.} = object
    error_message*: cstring
    status*: cint
proc encodeShutdownRequestToC(obj: ShutdownRequest): ShutdownRequestCResult =
  result.status = obj.status

proc free_shutdown_request_result(r: ptr ShutdownRequestCResult) {.
    exportc: "free_shutdown_request_result", cdecl, dynlib.} =
  if r.isNil:
    return
  if not r.error_message.isNil:
    freeCString(r.error_message)

proc shutdown_request(ctx: uint32): ShutdownRequestCResult {.
    exportc: "shutdown_request", cdecl, dynlib.} =
  let brokerCtx = BrokerContext(ctx)
  let res = waitFor ShutdownRequest.request(brokerCtx)
  if res.isOk():
    return encodeShutdownRequestToC(res.get())
  else:
    var errResult: ShutdownRequestCResult
    errResult.error_message = allocCStringCopy(res.error())
    return errResult
# ===== RequestBroker(API): AddDevice =====
## Flow:
## - This request shows seq[ApiType] argument marshalling through the API layer.
## - The C wrapper decodes pointer + count into `seq[AddDeviceSpec]`, then dispatches through the same MT broker runtime.
## Collapsed identical repeated expansion block.
## The removed copy was byte-for-byte identical to the first generated MT/runtime block.

type
  AddDevice* = object
    devices*: seq[DeviceInfo]
    success*: bool
  AddDeviceProviderWithArgs = proc (devices: seq[AddDeviceSpec]): Future[
      Result[AddDevice, string]] {.async.}
  AddDeviceMtRequestMsg = object
    isShutdown: bool
    requestKind: int
    devices: seq[AddDeviceSpec]
    responseChan: ptr AsyncChannel[Result[AddDevice, string]]
  AddDeviceMtBucket = object
    brokerCtx: BrokerContext
    requestChan: ptr AsyncChannel[AddDeviceMtRequestMsg]
    threadId: pointer
    threadGen: uint64
var gAddDeviceMtBuckets: ptr UncheckedArray[AddDeviceMtBucket]
var gAddDeviceMtBucketCount: int
var gAddDeviceMtBucketCap: int
var gAddDeviceMtLock: Lock
var gAddDeviceMtInit: Atomic[int] ## 0 = uninitialised, 1 = initialising, 2 = ready.
                                  ## CAS(0→1) wins the race; losers spin until 2.
proc ensureInitAddDeviceMtBroker() =
  if gAddDeviceMtInit.load(moRelaxed) == 2:
    return
  var expected = 0
  if gAddDeviceMtInit.compareExchange(expected, 1, moAcquire,
                                      moRelaxed):
    initLock(gAddDeviceMtLock)
    gAddDeviceMtBucketCap = 4
    gAddDeviceMtBuckets = cast[ptr UncheckedArray[AddDeviceMtBucket]](createShared(
        AddDeviceMtBucket, gAddDeviceMtBucketCap))
    gAddDeviceMtBucketCount = 0
    gAddDeviceMtInit.store(2, moRelease)
  else:
    while gAddDeviceMtInit.load(moAcquire) != 2:
      discard

proc growAddDeviceMtBuckets() =
  ## Must be called under lock.
  let newCap = gAddDeviceMtBucketCap * 2
  let newBuf = cast[ptr UncheckedArray[AddDeviceMtBucket]](createShared(
      AddDeviceMtBucket, newCap))
  for i in 0 ..< gAddDeviceMtBucketCount:
    newBuf[i] = gAddDeviceMtBuckets[i]
  deallocShared(gAddDeviceMtBuckets)
  gAddDeviceMtBuckets = newBuf
  gAddDeviceMtBucketCap = newCap

var gAddDeviceMtRequestTimeout*: Duration = seconds(5) ## Default timeout for cross-thread requests. Same-thread requests
                                                       ## bypass this (they call the provider directly).
                                                       ## NOTE: Set during initialization before spawning worker threads.
                                                       ## Reading from multiple threads is safe on x86-64 (aligned int64),
                                                       ## but concurrent writes are not guaranteed atomic on all platforms.
proc setRequestTimeout*(_: typedesc[AddDevice]; timeout: Duration) =
  ## Set the cross-thread request timeout for this broker type.
  ## Call this during initialization before spawning worker threads.
  gAddDeviceMtRequestTimeout = timeout

proc requestTimeout*(_: typedesc[AddDevice]): Duration =
  ## Get the current cross-thread request timeout for this broker type.
  gAddDeviceMtRequestTimeout

var gAddDeviceTvWithArgCtxs {.threadvar.}: seq[BrokerContext]
var gAddDeviceTvWithArgHandlers {.threadvar.}: seq[AddDeviceProviderWithArgs]
proc processLoopAddDevice(requestChan: ptr AsyncChannel[AddDeviceMtRequestMsg];
                          loopCtx: BrokerContext) {.async: (raises: []).} =
  while true:
    let recvRes = catch do:
      await requestChan.recv()
    if recvRes.isErr():
      break
    let msg = recvRes.get()
    if msg.isShutdown:
      break
    if msg.requestKind == 1:
      var handler1: AddDeviceProviderWithArgs
      for i in 0 ..< gAddDeviceTvWithArgCtxs.len:
        if gAddDeviceTvWithArgCtxs[i] == loopCtx:
          handler1 = gAddDeviceTvWithArgHandlers[i]
          break
      if handler1.isNil():
        msg.responseChan[].sendSync(err(Result[AddDevice, string], "RequestBroker(" &
            "AddDevice" &
            "): no provider registered for input signature"))
      else:
        let catchedRes = catch do:
          await handler1(msg.devices)
        if catchedRes.isErr():
          msg.responseChan[].sendSync(err(Result[AddDevice, string], "RequestBroker(" &
              "AddDevice" &
              "): provider threw exception: " &
              catchedRes.error.msg))
        else:
          let providerRes = catchedRes.get()
          if providerRes.isOk():
            let resultValue = providerRes.get()
            when compiles(resultValue.isNil()):
              if resultValue.isNil():
                msg.responseChan[].sendSync(err(Result[AddDevice, string], "RequestBroker(" &
                    "AddDevice" &
                    "): provider returned nil result"))
                continue
          msg.responseChan[].sendSync(providerRes)

proc setProvider*(_: typedesc[AddDevice];
                  handler: AddDeviceProviderWithArgs): Result[void,
    string] =
  ensureInitAddDeviceMtBroker()
  let myThreadGen = currentMtThreadGen()
  for i in 0 ..< gAddDeviceTvWithArgCtxs.len:
    if gAddDeviceTvWithArgCtxs[i] == DefaultBrokerContext:
      var isStale = true
      withLock(gAddDeviceMtLock):
        for j in 0 ..< gAddDeviceMtBucketCount:
          if gAddDeviceMtBuckets[j].brokerCtx ==
              DefaultBrokerContext and
              gAddDeviceMtBuckets[j].threadId ==
              currentMtThreadId() and
              gAddDeviceMtBuckets[j].threadGen ==
              myThreadGen:
            isStale = false
            break
      if isStale:
        gAddDeviceTvWithArgCtxs.del(i)
        gAddDeviceTvWithArgHandlers.del(i)
        break
      else:
        return err("Provider already set")
  gAddDeviceTvWithArgCtxs.add(DefaultBrokerContext)
  gAddDeviceTvWithArgHandlers.add(handler)
  var spawnChan: ptr AsyncChannel[AddDeviceMtRequestMsg]
  withLock(gAddDeviceMtLock):
    for i in 0 ..< gAddDeviceMtBucketCount:
      if gAddDeviceMtBuckets[i].brokerCtx == DefaultBrokerContext:
        if gAddDeviceMtBuckets[i].threadId == currentMtThreadId() and
            gAddDeviceMtBuckets[i].threadGen ==
            myThreadGen:
          return ok()
        else:
          gAddDeviceTvWithArgCtxs.setLen(gAddDeviceTvWithArgCtxs.len - 1)
          gAddDeviceTvWithArgHandlers.setLen(gAddDeviceTvWithArgHandlers.len - 1)
          return err("RequestBroker(" & "AddDevice" &
              "): provider already set from another thread")
    if gAddDeviceMtBucketCount >= gAddDeviceMtBucketCap:
      growAddDeviceMtBuckets()
    spawnChan = cast[ptr AsyncChannel[AddDeviceMtRequestMsg]](createShared(
        AsyncChannel[AddDeviceMtRequestMsg], 1))
    discard spawnChan[].open()
    let idx = gAddDeviceMtBucketCount
    gAddDeviceMtBuckets[idx] = AddDeviceMtBucket(
        brokerCtx: DefaultBrokerContext, requestChan: spawnChan,
        threadId: currentMtThreadId(), threadGen: myThreadGen)
    gAddDeviceMtBucketCount += 1
  if not spawnChan.isNil:
    asyncSpawn processLoopAddDevice(spawnChan, DefaultBrokerContext)
  return ok()

proc setProvider*(_: typedesc[AddDevice]; brokerCtx: BrokerContext;
                  handler: AddDeviceProviderWithArgs): Result[void,
    string] =
  if brokerCtx == DefaultBrokerContext:
    return setProvider(AddDevice, handler)
  ensureInitAddDeviceMtBroker()
  let myThreadGen = currentMtThreadGen()
  for i in 0 ..< gAddDeviceTvWithArgCtxs.len:
    if gAddDeviceTvWithArgCtxs[i] == brokerCtx:
      var isStale = true
      withLock(gAddDeviceMtLock):
        for j in 0 ..< gAddDeviceMtBucketCount:
          if gAddDeviceMtBuckets[j].brokerCtx ==
              brokerCtx and
              gAddDeviceMtBuckets[j].threadId ==
              currentMtThreadId() and
              gAddDeviceMtBuckets[j].threadGen ==
              myThreadGen:
            isStale = false
            break
      if isStale:
        gAddDeviceTvWithArgCtxs.del(i)
        gAddDeviceTvWithArgHandlers.del(i)
        break
      else:
        return err("RequestBroker(" & "AddDevice" &
            "): provider already set for broker context " &
            $brokerCtx)
  gAddDeviceTvWithArgCtxs.add(brokerCtx)
  gAddDeviceTvWithArgHandlers.add(handler)
  var spawnChan: ptr AsyncChannel[AddDeviceMtRequestMsg]
  withLock(gAddDeviceMtLock):
    for i in 0 ..< gAddDeviceMtBucketCount:
      if gAddDeviceMtBuckets[i].brokerCtx == brokerCtx:
        if gAddDeviceMtBuckets[i].threadId == currentMtThreadId() and
            gAddDeviceMtBuckets[i].threadGen ==
            myThreadGen:
          return ok()
        else:
          gAddDeviceTvWithArgCtxs.setLen(gAddDeviceTvWithArgCtxs.len - 1)
          gAddDeviceTvWithArgHandlers.setLen(gAddDeviceTvWithArgHandlers.len - 1)
          return err("RequestBroker(" & "AddDevice" &
              "): provider already set from another thread for context " &
              $brokerCtx)
    if gAddDeviceMtBucketCount >= gAddDeviceMtBucketCap:
      growAddDeviceMtBuckets()
    spawnChan = cast[ptr AsyncChannel[AddDeviceMtRequestMsg]](createShared(
        AsyncChannel[AddDeviceMtRequestMsg], 1))
    discard spawnChan[].open()
    let idx = gAddDeviceMtBucketCount
    gAddDeviceMtBuckets[idx] = AddDeviceMtBucket(
        brokerCtx: brokerCtx, requestChan: spawnChan,
        threadId: currentMtThreadId(), threadGen: myThreadGen)
    gAddDeviceMtBucketCount += 1
  if not spawnChan.isNil:
    asyncSpawn processLoopAddDevice(spawnChan, brokerCtx)
  return ok()

proc request*(_: typedesc[AddDevice]): Future[Result[AddDevice, string]] {.
    async: (raises: []).} =
  return err("RequestBroker(" & "AddDevice" &
      "): no zero-arg provider registered")

proc request*(_: typedesc[AddDevice]; devices: seq[AddDeviceSpec]): Future[
    Result[AddDevice, string]] {.async: (raises: []).} =
  return await request(AddDevice, DefaultBrokerContext, devices)

proc request*(_: typedesc[AddDevice]; brokerCtx: BrokerContext;
              devices: seq[AddDeviceSpec]): Future[Result[AddDevice, string]] {.
    async: (raises: []).} =
  ensureInitAddDeviceMtBroker()
  var reqChan: ptr AsyncChannel[AddDeviceMtRequestMsg]
  var sameThread = false
  let myThreadGen = currentMtThreadGen()
  withLock(gAddDeviceMtLock):
    for i in 0 ..< gAddDeviceMtBucketCount:
      if gAddDeviceMtBuckets[i].brokerCtx == brokerCtx:
        if gAddDeviceMtBuckets[i].threadId == currentMtThreadId() and
            gAddDeviceMtBuckets[i].threadGen ==
            myThreadGen:
          sameThread = true
        else:
          reqChan = gAddDeviceMtBuckets[i].requestChan
        break
  if sameThread:
    var provider: AddDeviceProviderWithArgs
    for i in 0 ..< gAddDeviceTvWithArgCtxs.len:
      if gAddDeviceTvWithArgCtxs[i] == brokerCtx:
        provider = gAddDeviceTvWithArgHandlers[i]
        break
    if provider.isNil():
      return err("RequestBroker(" & "AddDevice" &
          "): no provider registered for input signature")
    let catchedRes = catch do:
      await provider(devices)
    if catchedRes.isErr():
      return err("RequestBroker(" & "AddDevice" &
          "): provider threw exception: " &
          catchedRes.error.msg)
    let providerRes = catchedRes.get()
    if providerRes.isOk():
      let resultValue = providerRes.get()
      when compiles(resultValue.isNil()):
        if resultValue.isNil():
          return err("RequestBroker(" & "AddDevice" &
              "): provider returned nil result")
    return providerRes
  else:
    if reqChan.isNil():
      return err("RequestBroker(" & "AddDevice" &
          "): no provider registered for broker context " &
          $brokerCtx)
    let respChan = cast[ptr AsyncChannel[Result[AddDevice, string]]](createShared(
        AsyncChannel[Result[AddDevice, string]], 1))
    discard respChan[].open()
    var msg = AddDeviceMtRequestMsg(isShutdown: false, requestKind: 1,
        devices: devices, responseChan: respChan)
    reqChan[].sendSync(msg)
    let recvFut = respChan.recv()
    let completedRes = catch do:
      await withTimeout(recvFut, gAddDeviceMtRequestTimeout)
    if completedRes.isErr():
      return err("RequestBroker(" & "AddDevice" & "): recv failed: " &
          completedRes.error.msg)
    if not completedRes.get():
      return err("RequestBroker(" & "AddDevice" &
          "): cross-thread request timed out after " &
          $gAddDeviceMtRequestTimeout)
    respChan[].close()
    deallocShared(respChan)
    let recvRes = catch do:
      recvFut.read()
    if recvRes.isErr():
      return err("RequestBroker(" & "AddDevice" & "): recv failed: " &
          recvRes.error.msg)
    return recvRes.get()

proc clearProvider*(_: typedesc[AddDevice]; brokerCtx: BrokerContext) =
  ensureInitAddDeviceMtBroker()
  var reqChan: ptr AsyncChannel[AddDeviceMtRequestMsg]
  var isProviderThread = false
  let myThreadGen = currentMtThreadGen()
  withLock(gAddDeviceMtLock):
    var foundIdx = -1
    for i in 0 ..< gAddDeviceMtBucketCount:
      if gAddDeviceMtBuckets[i].brokerCtx == brokerCtx:
        reqChan = gAddDeviceMtBuckets[i].requestChan
        isProviderThread = (gAddDeviceMtBuckets[i].threadId ==
            currentMtThreadId() and
            gAddDeviceMtBuckets[i].threadGen ==
            myThreadGen)
        foundIdx = i
        break
    if foundIdx >= 0:
      for i in foundIdx ..< gAddDeviceMtBucketCount - 1:
        gAddDeviceMtBuckets[i] = gAddDeviceMtBuckets[i + 1]
      gAddDeviceMtBucketCount -= 1
  if isProviderThread:
    for i in countdown(gAddDeviceTvWithArgCtxs.len - 1, 0):
      if gAddDeviceTvWithArgCtxs[i] == brokerCtx:
        gAddDeviceTvWithArgCtxs.del(i)
        gAddDeviceTvWithArgHandlers.del(i)
        break
  elif not reqChan.isNil():
    trace "clearProvider called from non-provider thread; " &
        "threadvar entries on provider thread are stale but harmless " &
        "(next setProvider will detect and clean them)",
          brokerType = "AddDevice"
  if not reqChan.isNil():
    var shutdownMsg = AddDeviceMtRequestMsg(isShutdown: true)
    reqChan[].sendSync(shutdownMsg)

proc clearProvider*(_: typedesc[AddDevice]) =
  clearProvider(AddDevice, DefaultBrokerContext)

proc cleanupApiRequestProvider_AddDevice(ctx: BrokerContext) =
  AddDevice.clearProvider(ctx)

type
  AddDeviceCResult* {.exportc.} = object
    error_message*: cstring
    devices*: pointer
    devices_count*: cint
    success*: bool
proc encodeAddDeviceToC(obj: AddDevice): AddDeviceCResult =
  let n = obj.devices.len
  result.devices_count = cint(n)
  if n > 0:
    let arr = cast[ptr UncheckedArray[DeviceInfoCItem]](allocShared(
        n * sizeof(DeviceInfoCItem)))
    for i in 0 ..< n:
      arr[i] = encodeDeviceInfoToCItem(obj.devices[i])
    result.devices = cast[pointer](arr)
  result.success = obj.success

proc free_add_device_result(r: ptr AddDeviceCResult) {.
    exportc: "free_add_device_result", cdecl, dynlib.} =
  if r.isNil:
    return
  if not r.error_message.isNil:
    freeCString(r.error_message)
  if r.devices_count > 0 and not r.devices.isNil:
    let arr = cast[ptr UncheckedArray[DeviceInfoCItem]](r.devices)
    for j in 0 ..< r.devices_count:
      if not arr[j].name.isNil:
        freeCString(arr[j].name)
      if not arr[j].deviceType.isNil:
        freeCString(arr[j].deviceType)
      if not arr[j].address.isNil:
        freeCString(arr[j].address)
    deallocShared(r.devices)

proc add_device*(ctx: uint32; devices: pointer; devices_count: cint): AddDeviceCResult {.
    exportc: "add_device", cdecl, dynlib.} =
  let brokerCtx = BrokerContext(ctx)
  var nim_devices: seq[AddDeviceSpec] = @[]
  if devices_count > 0 and not devices.isNil:
    let arr_devices = cast[ptr UncheckedArray[AddDeviceSpecCItem]](devices)
    nim_devices = newSeqOfCap[AddDeviceSpec](int(devices_count))
    for i_devices in 0 ..< int(devices_count):
      nim_devices.add(AddDeviceSpec(name:
        if arr_devices[i_devices].name.isNil:
          ""
        else:
          $arr_devices[i_devices].name
      , deviceType:
        if arr_devices[i_devices].deviceType.isNil:
          ""
        else:
          $arr_devices[i_devices].deviceType
      , address:
        if arr_devices[i_devices].address.isNil:
          ""
        else:
          $arr_devices[i_devices].address
      ))
  let res = waitFor request(AddDevice, brokerCtx, nim_devices)
  if res.isOk():
    return encodeAddDeviceToC(res.get())
  else:
    var errResult: AddDeviceCResult
    errResult.error_message = allocCStringCopy(res.error())
    return errResult
# ===== RequestBroker(API): RemoveDevice =====
## Flow:
## - Single-argument request broker: provider registration, same-thread fast path, cross-thread AsyncChannel path, C result export.
## Collapsed identical repeated expansion block.
## The removed copy was byte-for-byte identical to the first generated MT/runtime block.

type
  RemoveDevice* = object
    success*: bool
  RemoveDeviceProviderWithArgs = proc (deviceId: int64): Future[
      Result[RemoveDevice, string]] {.async.}
  RemoveDeviceMtRequestMsg = object
    isShutdown: bool
    requestKind: int
    deviceId: int64
    responseChan: ptr AsyncChannel[Result[RemoveDevice, string]]
  RemoveDeviceMtBucket = object
    brokerCtx: BrokerContext
    requestChan: ptr AsyncChannel[RemoveDeviceMtRequestMsg]
    threadId: pointer
    threadGen: uint64
var gRemoveDeviceMtBuckets: ptr UncheckedArray[RemoveDeviceMtBucket]
var gRemoveDeviceMtBucketCount: int
var gRemoveDeviceMtBucketCap: int
var gRemoveDeviceMtLock: Lock
var gRemoveDeviceMtInit: Atomic[int] ## 0 = uninitialised, 1 = initialising, 2 = ready.
                                     ## CAS(0→1) wins the race; losers spin until 2.
proc ensureInitRemoveDeviceMtBroker() =
  if gRemoveDeviceMtInit.load(moRelaxed) == 2:
    return
  var expected = 0
  if gRemoveDeviceMtInit.compareExchange(expected, 1, moAcquire,
      moRelaxed):
    initLock(gRemoveDeviceMtLock)
    gRemoveDeviceMtBucketCap = 4
    gRemoveDeviceMtBuckets = cast[ptr UncheckedArray[RemoveDeviceMtBucket]](createShared(
        RemoveDeviceMtBucket, gRemoveDeviceMtBucketCap))
    gRemoveDeviceMtBucketCount = 0
    gRemoveDeviceMtInit.store(2, moRelease)
  else:
    while gRemoveDeviceMtInit.load(moAcquire) != 2:
      discard

proc growRemoveDeviceMtBuckets() =
  ## Must be called under lock.
  let newCap = gRemoveDeviceMtBucketCap * 2
  let newBuf = cast[ptr UncheckedArray[RemoveDeviceMtBucket]](createShared(
      RemoveDeviceMtBucket, newCap))
  for i in 0 ..< gRemoveDeviceMtBucketCount:
    newBuf[i] = gRemoveDeviceMtBuckets[i]
  deallocShared(gRemoveDeviceMtBuckets)
  gRemoveDeviceMtBuckets = newBuf
  gRemoveDeviceMtBucketCap = newCap

var gRemoveDeviceMtRequestTimeout*: Duration = seconds(5) ## Default timeout for cross-thread requests. Same-thread requests
                                                          ## bypass this (they call the provider directly).
                                                          ## NOTE: Set during initialization before spawning worker threads.
                                                          ## Reading from multiple threads is safe on x86-64 (aligned int64),
                                                          ## but concurrent writes are not guaranteed atomic on all platforms.
proc setRequestTimeout*(_: typedesc[RemoveDevice]; timeout: Duration) =
  ## Set the cross-thread request timeout for this broker type.
  ## Call this during initialization before spawning worker threads.
  gRemoveDeviceMtRequestTimeout = timeout

proc requestTimeout*(_: typedesc[RemoveDevice]): Duration =
  ## Get the current cross-thread request timeout for this broker type.
  gRemoveDeviceMtRequestTimeout

var gRemoveDeviceTvWithArgCtxs {.threadvar.}: seq[BrokerContext]
var gRemoveDeviceTvWithArgHandlers {.threadvar.}: seq[
    RemoveDeviceProviderWithArgs]
proc processLoopRemoveDevice(requestChan: ptr AsyncChannel[
    RemoveDeviceMtRequestMsg]; loopCtx: BrokerContext) {.async: (raises: []).} =
  while true:
    let recvRes = catch do:
      await requestChan.recv()
    if recvRes.isErr():
      break
    let msg = recvRes.get()
    if msg.isShutdown:
      break
    if msg.requestKind == 1:
      var handler1: RemoveDeviceProviderWithArgs
      for i in 0 ..< gRemoveDeviceTvWithArgCtxs.len:
        if gRemoveDeviceTvWithArgCtxs[i] == loopCtx:
          handler1 = gRemoveDeviceTvWithArgHandlers[i]
          break
      if handler1.isNil():
        msg.responseChan[].sendSync(err(Result[RemoveDevice, string], "RequestBroker(" &
            "RemoveDevice" &
            "): no provider registered for input signature"))
      else:
        let catchedRes = catch do:
          await handler1(msg.deviceId)
        if catchedRes.isErr():
          msg.responseChan[].sendSync(err(Result[RemoveDevice, string], "RequestBroker(" &
              "RemoveDevice" &
              "): provider threw exception: " &
              catchedRes.error.msg))
        else:
          let providerRes = catchedRes.get()
          if providerRes.isOk():
            let resultValue = providerRes.get()
            when compiles(resultValue.isNil()):
              if resultValue.isNil():
                msg.responseChan[].sendSync(err(
                    Result[RemoveDevice, string], "RequestBroker(" &
                    "RemoveDevice" &
                    "): provider returned nil result"))
                continue
          msg.responseChan[].sendSync(providerRes)

proc setProvider*(_: typedesc[RemoveDevice];
                  handler: RemoveDeviceProviderWithArgs): Result[
    void, string] =
  ensureInitRemoveDeviceMtBroker()
  let myThreadGen = currentMtThreadGen()
  for i in 0 ..< gRemoveDeviceTvWithArgCtxs.len:
    if gRemoveDeviceTvWithArgCtxs[i] == DefaultBrokerContext:
      var isStale = true
      withLock(gRemoveDeviceMtLock):
        for j in 0 ..< gRemoveDeviceMtBucketCount:
          if gRemoveDeviceMtBuckets[j].brokerCtx ==
              DefaultBrokerContext and
              gRemoveDeviceMtBuckets[j].threadId ==
              currentMtThreadId() and
              gRemoveDeviceMtBuckets[j].threadGen ==
              myThreadGen:
            isStale = false
            break
      if isStale:
        gRemoveDeviceTvWithArgCtxs.del(i)
        gRemoveDeviceTvWithArgHandlers.del(i)
        break
      else:
        return err("Provider already set")
  gRemoveDeviceTvWithArgCtxs.add(DefaultBrokerContext)
  gRemoveDeviceTvWithArgHandlers.add(handler)
  var spawnChan: ptr AsyncChannel[RemoveDeviceMtRequestMsg]
  withLock(gRemoveDeviceMtLock):
    for i in 0 ..< gRemoveDeviceMtBucketCount:
      if gRemoveDeviceMtBuckets[i].brokerCtx ==
          DefaultBrokerContext:
        if gRemoveDeviceMtBuckets[i].threadId ==
            currentMtThreadId() and
            gRemoveDeviceMtBuckets[i].threadGen ==
            myThreadGen:
          return ok()
        else:
          gRemoveDeviceTvWithArgCtxs.setLen(gRemoveDeviceTvWithArgCtxs.len - 1)
          gRemoveDeviceTvWithArgHandlers.setLen(
              gRemoveDeviceTvWithArgHandlers.len - 1)
          return err("RequestBroker(" & "RemoveDevice" &
              "): provider already set from another thread")
    if gRemoveDeviceMtBucketCount >= gRemoveDeviceMtBucketCap:
      growRemoveDeviceMtBuckets()
    spawnChan = cast[ptr AsyncChannel[RemoveDeviceMtRequestMsg]](createShared(
        AsyncChannel[RemoveDeviceMtRequestMsg], 1))
    discard spawnChan[].open()
    let idx = gRemoveDeviceMtBucketCount
    gRemoveDeviceMtBuckets[idx] = RemoveDeviceMtBucket(
        brokerCtx: DefaultBrokerContext, requestChan: spawnChan,
        threadId: currentMtThreadId(), threadGen: myThreadGen)
    gRemoveDeviceMtBucketCount += 1
  if not spawnChan.isNil:
    asyncSpawn processLoopRemoveDevice(spawnChan,
                                       DefaultBrokerContext)
  return ok()

proc setProvider*(_: typedesc[RemoveDevice];
                  brokerCtx: BrokerContext;
                  handler: RemoveDeviceProviderWithArgs): Result[
    void, string] =
  if brokerCtx == DefaultBrokerContext:
    return setProvider(RemoveDevice, handler)
  ensureInitRemoveDeviceMtBroker()
  let myThreadGen = currentMtThreadGen()
  for i in 0 ..< gRemoveDeviceTvWithArgCtxs.len:
    if gRemoveDeviceTvWithArgCtxs[i] == brokerCtx:
      var isStale = true
      withLock(gRemoveDeviceMtLock):
        for j in 0 ..< gRemoveDeviceMtBucketCount:
          if gRemoveDeviceMtBuckets[j].brokerCtx ==
              brokerCtx and
              gRemoveDeviceMtBuckets[j].threadId ==
              currentMtThreadId() and
              gRemoveDeviceMtBuckets[j].threadGen ==
              myThreadGen:
            isStale = false
            break
      if isStale:
        gRemoveDeviceTvWithArgCtxs.del(i)
        gRemoveDeviceTvWithArgHandlers.del(i)
        break
      else:
        return err("RequestBroker(" & "RemoveDevice" &
            "): provider already set for broker context " &
            $brokerCtx)
  gRemoveDeviceTvWithArgCtxs.add(brokerCtx)
  gRemoveDeviceTvWithArgHandlers.add(handler)
  var spawnChan: ptr AsyncChannel[RemoveDeviceMtRequestMsg]
  withLock(gRemoveDeviceMtLock):
    for i in 0 ..< gRemoveDeviceMtBucketCount:
      if gRemoveDeviceMtBuckets[i].brokerCtx ==
          brokerCtx:
        if gRemoveDeviceMtBuckets[i].threadId ==
            currentMtThreadId() and
            gRemoveDeviceMtBuckets[i].threadGen ==
            myThreadGen:
          return ok()
        else:
          gRemoveDeviceTvWithArgCtxs.setLen(gRemoveDeviceTvWithArgCtxs.len - 1)
          gRemoveDeviceTvWithArgHandlers.setLen(
              gRemoveDeviceTvWithArgHandlers.len - 1)
          return err("RequestBroker(" & "RemoveDevice" &
              "): provider already set from another thread for context " &
              $brokerCtx)
    if gRemoveDeviceMtBucketCount >= gRemoveDeviceMtBucketCap:
      growRemoveDeviceMtBuckets()
    spawnChan = cast[ptr AsyncChannel[RemoveDeviceMtRequestMsg]](createShared(
        AsyncChannel[RemoveDeviceMtRequestMsg], 1))
    discard spawnChan[].open()
    let idx = gRemoveDeviceMtBucketCount
    gRemoveDeviceMtBuckets[idx] = RemoveDeviceMtBucket(
        brokerCtx: brokerCtx, requestChan: spawnChan,
        threadId: currentMtThreadId(), threadGen: myThreadGen)
    gRemoveDeviceMtBucketCount += 1
  if not spawnChan.isNil:
    asyncSpawn processLoopRemoveDevice(spawnChan,
                                       brokerCtx)
  return ok()

proc request*(_: typedesc[RemoveDevice]): Future[
    Result[RemoveDevice, string]] {.async: (raises: []).} =
  return err("RequestBroker(" & "RemoveDevice" &
      "): no zero-arg provider registered")

proc request*(_: typedesc[RemoveDevice]; deviceId: int64): Future[
    Result[RemoveDevice, string]] {.async: (raises: []).} =
  return await request(RemoveDevice, DefaultBrokerContext, deviceId)

proc request*(_: typedesc[RemoveDevice]; brokerCtx: BrokerContext;
              deviceId: int64): Future[Result[RemoveDevice, string]] {.
    async: (raises: []).} =
  ensureInitRemoveDeviceMtBroker()
  var reqChan: ptr AsyncChannel[RemoveDeviceMtRequestMsg]
  var sameThread = false
  let myThreadGen = currentMtThreadGen()
  withLock(gRemoveDeviceMtLock):
    for i in 0 ..< gRemoveDeviceMtBucketCount:
      if gRemoveDeviceMtBuckets[i].brokerCtx == brokerCtx:
        if gRemoveDeviceMtBuckets[i].threadId ==
            currentMtThreadId() and
            gRemoveDeviceMtBuckets[i].threadGen ==
            myThreadGen:
          sameThread = true
        else:
          reqChan = gRemoveDeviceMtBuckets[i].requestChan
        break
  if sameThread:
    var provider: RemoveDeviceProviderWithArgs
    for i in 0 ..< gRemoveDeviceTvWithArgCtxs.len:
      if gRemoveDeviceTvWithArgCtxs[i] == brokerCtx:
        provider = gRemoveDeviceTvWithArgHandlers[i]
        break
    if provider.isNil():
      return err("RequestBroker(" & "RemoveDevice" &
          "): no provider registered for input signature")
    let catchedRes = catch do:
      await provider(deviceId)
    if catchedRes.isErr():
      return err("RequestBroker(" & "RemoveDevice" &
          "): provider threw exception: " &
          catchedRes.error.msg)
    let providerRes = catchedRes.get()
    if providerRes.isOk():
      let resultValue = providerRes.get()
      when compiles(resultValue.isNil()):
        if resultValue.isNil():
          return err("RequestBroker(" & "RemoveDevice" &
              "): provider returned nil result")
    return providerRes
  else:
    if reqChan.isNil():
      return err("RequestBroker(" & "RemoveDevice" &
          "): no provider registered for broker context " &
          $brokerCtx)
    let respChan = cast[ptr AsyncChannel[Result[RemoveDevice, string]]](createShared(
        AsyncChannel[Result[RemoveDevice, string]], 1))
    discard respChan[].open()
    var msg = RemoveDeviceMtRequestMsg(isShutdown: false,
        requestKind: 1, deviceId: deviceId, responseChan: respChan)
    reqChan[].sendSync(msg)
    let recvFut = respChan.recv()
    let completedRes = catch do:
      await withTimeout(recvFut, gRemoveDeviceMtRequestTimeout)
    if completedRes.isErr():
      return err("RequestBroker(" & "RemoveDevice" & "): recv failed: " &
          completedRes.error.msg)
    if not completedRes.get():
      return err("RequestBroker(" & "RemoveDevice" &
          "): cross-thread request timed out after " &
          $gRemoveDeviceMtRequestTimeout)
    respChan[].close()
    deallocShared(respChan)
    let recvRes = catch do:
      recvFut.read()
    if recvRes.isErr():
      return err("RequestBroker(" & "RemoveDevice" & "): recv failed: " &
          recvRes.error.msg)
    return recvRes.get()

proc clearProvider*(_: typedesc[RemoveDevice]; brokerCtx: BrokerContext) =
  ensureInitRemoveDeviceMtBroker()
  var reqChan: ptr AsyncChannel[RemoveDeviceMtRequestMsg]
  var isProviderThread = false
  let myThreadGen = currentMtThreadGen()
  withLock(gRemoveDeviceMtLock):
    var foundIdx = -1
    for i in 0 ..< gRemoveDeviceMtBucketCount:
      if gRemoveDeviceMtBuckets[i].brokerCtx == brokerCtx:
        reqChan = gRemoveDeviceMtBuckets[i].requestChan
        isProviderThread = (gRemoveDeviceMtBuckets[i].threadId ==
            currentMtThreadId() and
            gRemoveDeviceMtBuckets[i].threadGen ==
            myThreadGen)
        foundIdx = i
        break
    if foundIdx >= 0:
      for i in foundIdx ..< gRemoveDeviceMtBucketCount - 1:
        gRemoveDeviceMtBuckets[i] = gRemoveDeviceMtBuckets[
            i + 1]
      gRemoveDeviceMtBucketCount -= 1
  if isProviderThread:
    for i in countdown(gRemoveDeviceTvWithArgCtxs.len - 1, 0):
      if gRemoveDeviceTvWithArgCtxs[i] == brokerCtx:
        gRemoveDeviceTvWithArgCtxs.del(i)
        gRemoveDeviceTvWithArgHandlers.del(i)
        break
  elif not reqChan.isNil():
    trace "clearProvider called from non-provider thread; " &
        "threadvar entries on provider thread are stale but harmless " &
        "(next setProvider will detect and clean them)",
          brokerType = "RemoveDevice"
  if not reqChan.isNil():
    var shutdownMsg = RemoveDeviceMtRequestMsg(isShutdown: true)
    reqChan[].sendSync(shutdownMsg)

proc clearProvider*(_: typedesc[RemoveDevice]) =
  clearProvider(RemoveDevice, DefaultBrokerContext)

proc cleanupApiRequestProvider_RemoveDevice(ctx: BrokerContext) =
  RemoveDevice.clearProvider(ctx)

type
  RemoveDeviceCResult* {.exportc.} = object
    error_message*: cstring
    success*: bool
proc encodeRemoveDeviceToC(obj: RemoveDevice): RemoveDeviceCResult =
  result.success = obj.success

proc free_remove_device_result(r: ptr RemoveDeviceCResult) {.
    exportc: "free_remove_device_result", cdecl, dynlib.} =
  if r.isNil:
    return
  if not r.error_message.isNil:
    freeCString(r.error_message)

proc remove_device*(ctx: uint32; deviceId: int64): RemoveDeviceCResult {.
    exportc: "remove_device", cdecl, dynlib.} =
  let brokerCtx = BrokerContext(ctx)
  let res = waitFor request(RemoveDevice, brokerCtx, deviceId)
  if res.isOk():
    return encodeRemoveDeviceToC(res.get())
  else:
    var errResult: RemoveDeviceCResult
    errResult.error_message = allocCStringCopy(res.error())
    return errResult
# ===== RequestBroker(API): GetDevice =====
## Flow:
## - Same request-broker structure, with object result encoding back to the C ABI.
## Collapsed identical repeated expansion block.
## The removed copy was byte-for-byte identical to the first generated MT/runtime block.

type
  GetDevice* = object
    deviceId*: int64
    name*: string
    deviceType*: string
    address*: string
    online*: bool
  GetDeviceProviderWithArgs = proc (deviceId: int64): Future[
      Result[GetDevice, string]] {.async.}
  GetDeviceMtRequestMsg = object
    isShutdown: bool
    requestKind: int
    deviceId: int64
    responseChan: ptr AsyncChannel[Result[GetDevice, string]]
  GetDeviceMtBucket = object
    brokerCtx: BrokerContext
    requestChan: ptr AsyncChannel[GetDeviceMtRequestMsg]
    threadId: pointer
    threadGen: uint64
var gGetDeviceMtBuckets: ptr UncheckedArray[GetDeviceMtBucket]
var gGetDeviceMtBucketCount: int
var gGetDeviceMtBucketCap: int
var gGetDeviceMtLock: Lock
var gGetDeviceMtInit: Atomic[int] ## 0 = uninitialised, 1 = initialising, 2 = ready.
                                  ## CAS(0→1) wins the race; losers spin until 2.
proc ensureInitGetDeviceMtBroker() =
  if gGetDeviceMtInit.load(moRelaxed) == 2:
    return
  var expected = 0
  if gGetDeviceMtInit.compareExchange(expected, 1, moAcquire,
                                      moRelaxed):
    initLock(gGetDeviceMtLock)
    gGetDeviceMtBucketCap = 4
    gGetDeviceMtBuckets = cast[ptr UncheckedArray[GetDeviceMtBucket]](createShared(
        GetDeviceMtBucket, gGetDeviceMtBucketCap))
    gGetDeviceMtBucketCount = 0
    gGetDeviceMtInit.store(2, moRelease)
  else:
    while gGetDeviceMtInit.load(moAcquire) != 2:
      discard

proc growGetDeviceMtBuckets() =
  ## Must be called under lock.
  let newCap = gGetDeviceMtBucketCap * 2
  let newBuf = cast[ptr UncheckedArray[GetDeviceMtBucket]](createShared(
      GetDeviceMtBucket, newCap))
  for i in 0 ..< gGetDeviceMtBucketCount:
    newBuf[i] = gGetDeviceMtBuckets[i]
  deallocShared(gGetDeviceMtBuckets)
  gGetDeviceMtBuckets = newBuf
  gGetDeviceMtBucketCap = newCap

var gGetDeviceMtRequestTimeout*: Duration = seconds(5) ## Default timeout for cross-thread requests. Same-thread requests
                                                       ## bypass this (they call the provider directly).
                                                       ## NOTE: Set during initialization before spawning worker threads.
                                                       ## Reading from multiple threads is safe on x86-64 (aligned int64),
                                                       ## but concurrent writes are not guaranteed atomic on all platforms.
proc setRequestTimeout*(_: typedesc[GetDevice]; timeout: Duration) =
  ## Set the cross-thread request timeout for this broker type.
  ## Call this during initialization before spawning worker threads.
  gGetDeviceMtRequestTimeout = timeout

proc requestTimeout*(_: typedesc[GetDevice]): Duration =
  ## Get the current cross-thread request timeout for this broker type.
  gGetDeviceMtRequestTimeout

var gGetDeviceTvWithArgCtxs {.threadvar.}: seq[BrokerContext]
var gGetDeviceTvWithArgHandlers {.threadvar.}: seq[GetDeviceProviderWithArgs]
proc processLoopGetDevice(requestChan: ptr AsyncChannel[GetDeviceMtRequestMsg];
                          loopCtx: BrokerContext) {.async: (raises: []).} =
  while true:
    let recvRes = catch do:
      await requestChan.recv()
    if recvRes.isErr():
      break
    let msg = recvRes.get()
    if msg.isShutdown:
      break
    if msg.requestKind == 1:
      var handler1: GetDeviceProviderWithArgs
      for i in 0 ..< gGetDeviceTvWithArgCtxs.len:
        if gGetDeviceTvWithArgCtxs[i] == loopCtx:
          handler1 = gGetDeviceTvWithArgHandlers[i]
          break
      if handler1.isNil():
        msg.responseChan[].sendSync(err(Result[GetDevice, string], "RequestBroker(" &
            "GetDevice" &
            "): no provider registered for input signature"))
      else:
        let catchedRes = catch do:
          await handler1(msg.deviceId)
        if catchedRes.isErr():
          msg.responseChan[].sendSync(err(Result[GetDevice, string], "RequestBroker(" &
              "GetDevice" &
              "): provider threw exception: " &
              catchedRes.error.msg))
        else:
          let providerRes = catchedRes.get()
          if providerRes.isOk():
            let resultValue = providerRes.get()
            when compiles(resultValue.isNil()):
              if resultValue.isNil():
                msg.responseChan[].sendSync(err(Result[GetDevice, string], "RequestBroker(" &
                    "GetDevice" &
                    "): provider returned nil result"))
                continue
          msg.responseChan[].sendSync(providerRes)

proc setProvider*(_: typedesc[GetDevice];
                  handler: GetDeviceProviderWithArgs): Result[void,
    string] =
  ensureInitGetDeviceMtBroker()
  let myThreadGen = currentMtThreadGen()
  for i in 0 ..< gGetDeviceTvWithArgCtxs.len:
    if gGetDeviceTvWithArgCtxs[i] == DefaultBrokerContext:
      var isStale = true
      withLock(gGetDeviceMtLock):
        for j in 0 ..< gGetDeviceMtBucketCount:
          if gGetDeviceMtBuckets[j].brokerCtx ==
              DefaultBrokerContext and
              gGetDeviceMtBuckets[j].threadId ==
              currentMtThreadId() and
              gGetDeviceMtBuckets[j].threadGen ==
              myThreadGen:
            isStale = false
            break
      if isStale:
        gGetDeviceTvWithArgCtxs.del(i)
        gGetDeviceTvWithArgHandlers.del(i)
        break
      else:
        return err("Provider already set")
  gGetDeviceTvWithArgCtxs.add(DefaultBrokerContext)
  gGetDeviceTvWithArgHandlers.add(handler)
  var spawnChan: ptr AsyncChannel[GetDeviceMtRequestMsg]
  withLock(gGetDeviceMtLock):
    for i in 0 ..< gGetDeviceMtBucketCount:
      if gGetDeviceMtBuckets[i].brokerCtx == DefaultBrokerContext:
        if gGetDeviceMtBuckets[i].threadId == currentMtThreadId() and
            gGetDeviceMtBuckets[i].threadGen ==
            myThreadGen:
          return ok()
        else:
          gGetDeviceTvWithArgCtxs.setLen(gGetDeviceTvWithArgCtxs.len - 1)
          gGetDeviceTvWithArgHandlers.setLen(gGetDeviceTvWithArgHandlers.len - 1)
          return err("RequestBroker(" & "GetDevice" &
              "): provider already set from another thread")
    if gGetDeviceMtBucketCount >= gGetDeviceMtBucketCap:
      growGetDeviceMtBuckets()
    spawnChan = cast[ptr AsyncChannel[GetDeviceMtRequestMsg]](createShared(
        AsyncChannel[GetDeviceMtRequestMsg], 1))
    discard spawnChan[].open()
    let idx = gGetDeviceMtBucketCount
    gGetDeviceMtBuckets[idx] = GetDeviceMtBucket(
        brokerCtx: DefaultBrokerContext, requestChan: spawnChan,
        threadId: currentMtThreadId(), threadGen: myThreadGen)
    gGetDeviceMtBucketCount += 1
  if not spawnChan.isNil:
    asyncSpawn processLoopGetDevice(spawnChan, DefaultBrokerContext)
  return ok()

proc setProvider*(_: typedesc[GetDevice]; brokerCtx: BrokerContext;
                  handler: GetDeviceProviderWithArgs): Result[void,
    string] =
  if brokerCtx == DefaultBrokerContext:
    return setProvider(GetDevice, handler)
  ensureInitGetDeviceMtBroker()
  let myThreadGen = currentMtThreadGen()
  for i in 0 ..< gGetDeviceTvWithArgCtxs.len:
    if gGetDeviceTvWithArgCtxs[i] == brokerCtx:
      var isStale = true
      withLock(gGetDeviceMtLock):
        for j in 0 ..< gGetDeviceMtBucketCount:
          if gGetDeviceMtBuckets[j].brokerCtx ==
              brokerCtx and
              gGetDeviceMtBuckets[j].threadId ==
              currentMtThreadId() and
              gGetDeviceMtBuckets[j].threadGen ==
              myThreadGen:
            isStale = false
            break
      if isStale:
        gGetDeviceTvWithArgCtxs.del(i)
        gGetDeviceTvWithArgHandlers.del(i)
        break
      else:
        return err("RequestBroker(" & "GetDevice" &
            "): provider already set for broker context " &
            $brokerCtx)
  gGetDeviceTvWithArgCtxs.add(brokerCtx)
  gGetDeviceTvWithArgHandlers.add(handler)
  var spawnChan: ptr AsyncChannel[GetDeviceMtRequestMsg]
  withLock(gGetDeviceMtLock):
    for i in 0 ..< gGetDeviceMtBucketCount:
      if gGetDeviceMtBuckets[i].brokerCtx == brokerCtx:
        if gGetDeviceMtBuckets[i].threadId == currentMtThreadId() and
            gGetDeviceMtBuckets[i].threadGen ==
            myThreadGen:
          return ok()
        else:
          gGetDeviceTvWithArgCtxs.setLen(gGetDeviceTvWithArgCtxs.len - 1)
          gGetDeviceTvWithArgHandlers.setLen(gGetDeviceTvWithArgHandlers.len - 1)
          return err("RequestBroker(" & "GetDevice" &
              "): provider already set from another thread for context " &
              $brokerCtx)
    if gGetDeviceMtBucketCount >= gGetDeviceMtBucketCap:
      growGetDeviceMtBuckets()
    spawnChan = cast[ptr AsyncChannel[GetDeviceMtRequestMsg]](createShared(
        AsyncChannel[GetDeviceMtRequestMsg], 1))
    discard spawnChan[].open()
    let idx = gGetDeviceMtBucketCount
    gGetDeviceMtBuckets[idx] = GetDeviceMtBucket(
        brokerCtx: brokerCtx, requestChan: spawnChan,
        threadId: currentMtThreadId(), threadGen: myThreadGen)
    gGetDeviceMtBucketCount += 1
  if not spawnChan.isNil:
    asyncSpawn processLoopGetDevice(spawnChan, brokerCtx)
  return ok()

proc request*(_: typedesc[GetDevice]): Future[Result[GetDevice, string]] {.
    async: (raises: []).} =
  return err("RequestBroker(" & "GetDevice" &
      "): no zero-arg provider registered")

proc request*(_: typedesc[GetDevice]; deviceId: int64): Future[
    Result[GetDevice, string]] {.async: (raises: []).} =
  return await request(GetDevice, DefaultBrokerContext, deviceId)

proc request*(_: typedesc[GetDevice]; brokerCtx: BrokerContext; deviceId: int64): Future[
    Result[GetDevice, string]] {.async: (raises: []).} =
  ensureInitGetDeviceMtBroker()
  var reqChan: ptr AsyncChannel[GetDeviceMtRequestMsg]
  var sameThread = false
  let myThreadGen = currentMtThreadGen()
  withLock(gGetDeviceMtLock):
    for i in 0 ..< gGetDeviceMtBucketCount:
      if gGetDeviceMtBuckets[i].brokerCtx == brokerCtx:
        if gGetDeviceMtBuckets[i].threadId == currentMtThreadId() and
            gGetDeviceMtBuckets[i].threadGen ==
            myThreadGen:
          sameThread = true
        else:
          reqChan = gGetDeviceMtBuckets[i].requestChan
        break
  if sameThread:
    var provider: GetDeviceProviderWithArgs
    for i in 0 ..< gGetDeviceTvWithArgCtxs.len:
      if gGetDeviceTvWithArgCtxs[i] == brokerCtx:
        provider = gGetDeviceTvWithArgHandlers[i]
        break
    if provider.isNil():
      return err("RequestBroker(" & "GetDevice" &
          "): no provider registered for input signature")
    let catchedRes = catch do:
      await provider(deviceId)
    if catchedRes.isErr():
      return err("RequestBroker(" & "GetDevice" &
          "): provider threw exception: " &
          catchedRes.error.msg)
    let providerRes = catchedRes.get()
    if providerRes.isOk():
      let resultValue = providerRes.get()
      when compiles(resultValue.isNil()):
        if resultValue.isNil():
          return err("RequestBroker(" & "GetDevice" &
              "): provider returned nil result")
    return providerRes
  else:
    if reqChan.isNil():
      return err("RequestBroker(" & "GetDevice" &
          "): no provider registered for broker context " &
          $brokerCtx)
    let respChan = cast[ptr AsyncChannel[Result[GetDevice, string]]](createShared(
        AsyncChannel[Result[GetDevice, string]], 1))
    discard respChan[].open()
    var msg = GetDeviceMtRequestMsg(isShutdown: false,
        requestKind: 1, deviceId: deviceId, responseChan: respChan)
    reqChan[].sendSync(msg)
    let recvFut = respChan.recv()
    let completedRes = catch do:
      await withTimeout(recvFut, gGetDeviceMtRequestTimeout)
    if completedRes.isErr():
      return err("RequestBroker(" & "GetDevice" & "): recv failed: " &
          completedRes.error.msg)
    if not completedRes.get():
      return err("RequestBroker(" & "GetDevice" &
          "): cross-thread request timed out after " &
          $gGetDeviceMtRequestTimeout)
    respChan[].close()
    deallocShared(respChan)
    let recvRes = catch do:
      recvFut.read()
    if recvRes.isErr():
      return err("RequestBroker(" & "GetDevice" & "): recv failed: " &
          recvRes.error.msg)
    return recvRes.get()

proc clearProvider*(_: typedesc[GetDevice]; brokerCtx: BrokerContext) =
  ensureInitGetDeviceMtBroker()
  var reqChan: ptr AsyncChannel[GetDeviceMtRequestMsg]
  var isProviderThread = false
  let myThreadGen = currentMtThreadGen()
  withLock(gGetDeviceMtLock):
    var foundIdx = -1
    for i in 0 ..< gGetDeviceMtBucketCount:
      if gGetDeviceMtBuckets[i].brokerCtx == brokerCtx:
        reqChan = gGetDeviceMtBuckets[i].requestChan
        isProviderThread = (gGetDeviceMtBuckets[i].threadId ==
            currentMtThreadId() and
            gGetDeviceMtBuckets[i].threadGen ==
            myThreadGen)
        foundIdx = i
        break
    if foundIdx >= 0:
      for i in foundIdx ..< gGetDeviceMtBucketCount - 1:
        gGetDeviceMtBuckets[i] = gGetDeviceMtBuckets[i + 1]
      gGetDeviceMtBucketCount -= 1
  if isProviderThread:
    for i in countdown(gGetDeviceTvWithArgCtxs.len - 1, 0):
      if gGetDeviceTvWithArgCtxs[i] == brokerCtx:
        gGetDeviceTvWithArgCtxs.del(i)
        gGetDeviceTvWithArgHandlers.del(i)
        break
  elif not reqChan.isNil():
    trace "clearProvider called from non-provider thread; " &
        "threadvar entries on provider thread are stale but harmless " &
        "(next setProvider will detect and clean them)",
          brokerType = "GetDevice"
  if not reqChan.isNil():
    var shutdownMsg = GetDeviceMtRequestMsg(isShutdown: true)
    reqChan[].sendSync(shutdownMsg)

proc clearProvider*(_: typedesc[GetDevice]) =
  clearProvider(GetDevice, DefaultBrokerContext)

proc cleanupApiRequestProvider_GetDevice(ctx: BrokerContext) =
  GetDevice.clearProvider(ctx)

type
  GetDeviceCResult* {.exportc.} = object
    error_message*: cstring
    deviceId*: int64
    name*: cstring
    deviceType*: cstring
    address*: cstring
    online*: bool
proc encodeGetDeviceToC(obj: GetDevice): GetDeviceCResult =
  result.deviceId = obj.deviceId
  result.name = allocCStringCopy(obj.name)
  result.deviceType = allocCStringCopy(obj.deviceType)
  result.address = allocCStringCopy(obj.address)
  result.online = obj.online

proc free_get_device_result(r: ptr GetDeviceCResult) {.
    exportc: "free_get_device_result", cdecl, dynlib.} =
  if r.isNil:
    return
  if not r.error_message.isNil:
    freeCString(r.error_message)
  if not r.name.isNil:
    freeCString(r.name)
  if not r.deviceType.isNil:
    freeCString(r.deviceType)
  if not r.address.isNil:
    freeCString(r.address)

proc get_device*(ctx: uint32; deviceId: int64): GetDeviceCResult {.
    exportc: "get_device", cdecl, dynlib.} =
  let brokerCtx = BrokerContext(ctx)
  let res = waitFor request(GetDevice, brokerCtx, deviceId)
  if res.isOk():
    return encodeGetDeviceToC(res.get())
  else:
    var errResult: GetDeviceCResult
    errResult.error_message = allocCStringCopy(res.error())
    return errResult
# ===== RequestBroker(API): ListDevices =====
## Flow:
## - Zero-argument request whose result contains a sequence; the tail allocates and frees the C array representation.
## Collapsed identical repeated expansion block.
## The removed copy was byte-for-byte identical to the first generated MT/runtime block.

type
  ListDevices* = object
    devices*: seq[DeviceInfo]
  ListDevicesProviderNoArgs = proc (): Future[Result[ListDevices, string]] {.
      async.}
  ListDevicesMtRequestMsg = object
    isShutdown: bool
    requestKind: int
    responseChan: ptr AsyncChannel[Result[ListDevices, string]]
  ListDevicesMtBucket = object
    brokerCtx: BrokerContext
    requestChan: ptr AsyncChannel[ListDevicesMtRequestMsg]
    threadId: pointer
    threadGen: uint64
var gListDevicesMtBuckets: ptr UncheckedArray[ListDevicesMtBucket]
var gListDevicesMtBucketCount: int
var gListDevicesMtBucketCap: int
var gListDevicesMtLock: Lock
var gListDevicesMtInit: Atomic[int] ## 0 = uninitialised, 1 = initialising, 2 = ready.
                                    ## CAS(0→1) wins the race; losers spin until 2.
proc ensureInitListDevicesMtBroker() =
  if gListDevicesMtInit.load(moRelaxed) == 2:
    return
  var expected = 0
  if gListDevicesMtInit.compareExchange(expected, 1, moAcquire,
                                        moRelaxed):
    initLock(gListDevicesMtLock)
    gListDevicesMtBucketCap = 4
    gListDevicesMtBuckets = cast[ptr UncheckedArray[ListDevicesMtBucket]](createShared(
        ListDevicesMtBucket, gListDevicesMtBucketCap))
    gListDevicesMtBucketCount = 0
    gListDevicesMtInit.store(2, moRelease)
  else:
    while gListDevicesMtInit.load(moAcquire) != 2:
      discard

proc growListDevicesMtBuckets() =
  ## Must be called under lock.
  let newCap = gListDevicesMtBucketCap * 2
  let newBuf = cast[ptr UncheckedArray[ListDevicesMtBucket]](createShared(
      ListDevicesMtBucket, newCap))
  for i in 0 ..< gListDevicesMtBucketCount:
    newBuf[i] = gListDevicesMtBuckets[i]
  deallocShared(gListDevicesMtBuckets)
  gListDevicesMtBuckets = newBuf
  gListDevicesMtBucketCap = newCap

var gListDevicesMtRequestTimeout*: Duration = seconds(5) ## Default timeout for cross-thread requests. Same-thread requests
                                                         ## bypass this (they call the provider directly).
                                                         ## NOTE: Set during initialization before spawning worker threads.
                                                         ## Reading from multiple threads is safe on x86-64 (aligned int64),
                                                         ## but concurrent writes are not guaranteed atomic on all platforms.
proc setRequestTimeout*(_: typedesc[ListDevices]; timeout: Duration) =
  ## Set the cross-thread request timeout for this broker type.
  ## Call this during initialization before spawning worker threads.
  gListDevicesMtRequestTimeout = timeout

proc requestTimeout*(_: typedesc[ListDevices]): Duration =
  ## Get the current cross-thread request timeout for this broker type.
  gListDevicesMtRequestTimeout

var gListDevicesTvNoArgCtxs {.threadvar.}: seq[BrokerContext]
var gListDevicesTvNoArgHandlers {.threadvar.}: seq[ListDevicesProviderNoArgs]
proc processLoopListDevices(requestChan: ptr AsyncChannel[
    ListDevicesMtRequestMsg]; loopCtx: BrokerContext) {.async: (raises: []).} =
  while true:
    let recvRes = catch do:
      await requestChan.recv()
    if recvRes.isErr():
      break
    let msg = recvRes.get()
    if msg.isShutdown:
      break
    if msg.requestKind == 0:
      var handler0: ListDevicesProviderNoArgs
      for i in 0 ..< gListDevicesTvNoArgCtxs.len:
        if gListDevicesTvNoArgCtxs[i] == loopCtx:
          handler0 = gListDevicesTvNoArgHandlers[i]
          break
      if handler0.isNil():
        msg.responseChan[].sendSync(err(Result[ListDevices, string], "RequestBroker(" &
            "ListDevices" &
            "): no zero-arg provider registered"))
      else:
        let catchedRes = catch do:
          await handler0()
        if catchedRes.isErr():
          msg.responseChan[].sendSync(err(Result[ListDevices, string], "RequestBroker(" &
              "ListDevices" &
              "): provider threw exception: " &
              catchedRes.error.msg))
        else:
          let providerRes = catchedRes.get()
          if providerRes.isOk():
            let resultValue = providerRes.get()
            when compiles(resultValue.isNil()):
              if resultValue.isNil():
                msg.responseChan[].sendSync(err(Result[ListDevices, string], "RequestBroker(" &
                    "ListDevices" &
                    "): provider returned nil result"))
                continue
          msg.responseChan[].sendSync(providerRes)

proc setProvider*(_: typedesc[ListDevices];
                  handler: ListDevicesProviderNoArgs): Result[void,
    string] =
  ensureInitListDevicesMtBroker()
  let myThreadGen = currentMtThreadGen()
  for i in 0 ..< gListDevicesTvNoArgCtxs.len:
    if gListDevicesTvNoArgCtxs[i] == DefaultBrokerContext:
      var isStale = true
      withLock(gListDevicesMtLock):
        for j in 0 ..< gListDevicesMtBucketCount:
          if gListDevicesMtBuckets[j].brokerCtx ==
              DefaultBrokerContext and
              gListDevicesMtBuckets[j].threadId ==
              currentMtThreadId() and
              gListDevicesMtBuckets[j].threadGen ==
              myThreadGen:
            isStale = false
            break
      if isStale:
        gListDevicesTvNoArgCtxs.del(i)
        gListDevicesTvNoArgHandlers.del(i)
        break
      else:
        return err("Zero-arg provider already set")
  gListDevicesTvNoArgCtxs.add(DefaultBrokerContext)
  gListDevicesTvNoArgHandlers.add(handler)
  var spawnChan: ptr AsyncChannel[ListDevicesMtRequestMsg]
  withLock(gListDevicesMtLock):
    for i in 0 ..< gListDevicesMtBucketCount:
      if gListDevicesMtBuckets[i].brokerCtx ==
          DefaultBrokerContext:
        if gListDevicesMtBuckets[i].threadId ==
            currentMtThreadId() and
            gListDevicesMtBuckets[i].threadGen ==
            myThreadGen:
          return ok()
        else:
          gListDevicesTvNoArgCtxs.setLen(gListDevicesTvNoArgCtxs.len - 1)
          gListDevicesTvNoArgHandlers.setLen(gListDevicesTvNoArgHandlers.len - 1)
          return err("RequestBroker(" & "ListDevices" &
              "): provider already set from another thread")
    if gListDevicesMtBucketCount >= gListDevicesMtBucketCap:
      growListDevicesMtBuckets()
    spawnChan = cast[ptr AsyncChannel[ListDevicesMtRequestMsg]](createShared(
        AsyncChannel[ListDevicesMtRequestMsg], 1))
    discard spawnChan[].open()
    let idx = gListDevicesMtBucketCount
    gListDevicesMtBuckets[idx] = ListDevicesMtBucket(
        brokerCtx: DefaultBrokerContext, requestChan: spawnChan,
        threadId: currentMtThreadId(), threadGen: myThreadGen)
    gListDevicesMtBucketCount += 1
  asyncSpawn processLoopListDevices(spawnChan, DefaultBrokerContext)
  return ok()

proc setProvider*(_: typedesc[ListDevices]; brokerCtx: BrokerContext;
                  handler: ListDevicesProviderNoArgs): Result[void,
    string] =
  if brokerCtx == DefaultBrokerContext:
    return setProvider(ListDevices, handler)
  ensureInitListDevicesMtBroker()
  let myThreadGen = currentMtThreadGen()
  for i in 0 ..< gListDevicesTvNoArgCtxs.len:
    if gListDevicesTvNoArgCtxs[i] == brokerCtx:
      var isStale = true
      withLock(gListDevicesMtLock):
        for j in 0 ..< gListDevicesMtBucketCount:
          if gListDevicesMtBuckets[j].brokerCtx ==
              brokerCtx and
              gListDevicesMtBuckets[j].threadId ==
              currentMtThreadId() and
              gListDevicesMtBuckets[j].threadGen ==
              myThreadGen:
            isStale = false
            break
      if isStale:
        gListDevicesTvNoArgCtxs.del(i)
        gListDevicesTvNoArgHandlers.del(i)
        break
      else:
        return err("RequestBroker(" & "ListDevices" &
            "): zero-arg provider already set for broker context " &
            $brokerCtx)
  gListDevicesTvNoArgCtxs.add(brokerCtx)
  gListDevicesTvNoArgHandlers.add(handler)
  var spawnChan: ptr AsyncChannel[ListDevicesMtRequestMsg]
  withLock(gListDevicesMtLock):
    for i in 0 ..< gListDevicesMtBucketCount:
      if gListDevicesMtBuckets[i].brokerCtx ==
          brokerCtx:
        if gListDevicesMtBuckets[i].threadId ==
            currentMtThreadId() and
            gListDevicesMtBuckets[i].threadGen ==
            myThreadGen:
          return ok()
        else:
          gListDevicesTvNoArgCtxs.setLen(gListDevicesTvNoArgCtxs.len - 1)
          gListDevicesTvNoArgHandlers.setLen(gListDevicesTvNoArgHandlers.len - 1)
          return err("RequestBroker(" & "ListDevices" &
              "): provider already set from another thread for context " &
              $brokerCtx)
    if gListDevicesMtBucketCount >= gListDevicesMtBucketCap:
      growListDevicesMtBuckets()
    spawnChan = cast[ptr AsyncChannel[ListDevicesMtRequestMsg]](createShared(
        AsyncChannel[ListDevicesMtRequestMsg], 1))
    discard spawnChan[].open()
    let idx = gListDevicesMtBucketCount
    gListDevicesMtBuckets[idx] = ListDevicesMtBucket(
        brokerCtx: brokerCtx, requestChan: spawnChan,
        threadId: currentMtThreadId(), threadGen: myThreadGen)
    gListDevicesMtBucketCount += 1
  asyncSpawn processLoopListDevices(spawnChan, brokerCtx)
  return ok()

proc request*(_: typedesc[ListDevices]): Future[Result[ListDevices, string]] {.
    async: (raises: []).} =
  return await request(ListDevices, DefaultBrokerContext)

proc request*(_: typedesc[ListDevices]; brokerCtx: BrokerContext): Future[
    Result[ListDevices, string]] {.async: (raises: []).} =
  ensureInitListDevicesMtBroker()
  var reqChan: ptr AsyncChannel[ListDevicesMtRequestMsg]
  var sameThread = false
  let myThreadGen = currentMtThreadGen()
  withLock(gListDevicesMtLock):
    for i in 0 ..< gListDevicesMtBucketCount:
      if gListDevicesMtBuckets[i].brokerCtx ==
          brokerCtx:
        if gListDevicesMtBuckets[i].threadId ==
            currentMtThreadId() and
            gListDevicesMtBuckets[i].threadGen ==
            myThreadGen:
          sameThread = true
        else:
          reqChan = gListDevicesMtBuckets[i].requestChan
        break
  if sameThread:
    var provider: ListDevicesProviderNoArgs
    for i in 0 ..< gListDevicesTvNoArgCtxs.len:
      if gListDevicesTvNoArgCtxs[i] == brokerCtx:
        provider = gListDevicesTvNoArgHandlers[i]
        break
    if provider.isNil():
      return err("RequestBroker(" & "ListDevices" &
          "): no zero-arg provider registered")
    let catchedRes = catch do:
      await provider()
    if catchedRes.isErr():
      return err("RequestBroker(" & "ListDevices" &
          "): provider threw exception: " &
          catchedRes.error.msg)
    let providerRes = catchedRes.get()
    if providerRes.isOk():
      let resultValue = providerRes.get()
      when compiles(resultValue.isNil()):
        if resultValue.isNil():
          return err("RequestBroker(" & "ListDevices" &
              "): provider returned nil result")
    return providerRes
  else:
    if reqChan.isNil():
      return err("RequestBroker(" & "ListDevices" &
          "): no zero-arg provider registered for broker context " &
          $brokerCtx)
    let respChan = cast[ptr AsyncChannel[
        Result[ListDevices, string]]](createShared(
        AsyncChannel[Result[ListDevices, string]], 1))
    discard respChan[].open()
    var msg = ListDevicesMtRequestMsg(isShutdown: false,
        requestKind: 0, responseChan: respChan)
    reqChan[].sendSync(msg)
    let recvFut = respChan.recv()
    let completedRes = catch do:
      await withTimeout(recvFut, gListDevicesMtRequestTimeout)
    if completedRes.isErr():
      return err("RequestBroker(" & "ListDevices" & "): recv failed: " &
          completedRes.error.msg)
    if not completedRes.get():
      return err("RequestBroker(" & "ListDevices" &
          "): cross-thread request timed out after " &
          $gListDevicesMtRequestTimeout)
    respChan[].close()
    deallocShared(respChan)
    let recvRes = catch do:
      recvFut.read()
    if recvRes.isErr():
      return err("RequestBroker(" & "ListDevices" & "): recv failed: " &
          recvRes.error.msg)
    return recvRes.get()

proc clearProvider*(_: typedesc[ListDevices]; brokerCtx: BrokerContext) =
  ensureInitListDevicesMtBroker()
  var reqChan: ptr AsyncChannel[ListDevicesMtRequestMsg]
  var isProviderThread = false
  let myThreadGen = currentMtThreadGen()
  withLock(gListDevicesMtLock):
    var foundIdx = -1
    for i in 0 ..< gListDevicesMtBucketCount:
      if gListDevicesMtBuckets[i].brokerCtx == brokerCtx:
        reqChan = gListDevicesMtBuckets[i].requestChan
        isProviderThread = (gListDevicesMtBuckets[i].threadId ==
            currentMtThreadId() and
            gListDevicesMtBuckets[i].threadGen ==
            myThreadGen)
        foundIdx = i
        break
    if foundIdx >= 0:
      for i in foundIdx ..< gListDevicesMtBucketCount - 1:
        gListDevicesMtBuckets[i] = gListDevicesMtBuckets[
            i + 1]
      gListDevicesMtBucketCount -= 1
  if isProviderThread:
    for i in countdown(gListDevicesTvNoArgCtxs.len - 1, 0):
      if gListDevicesTvNoArgCtxs[i] == brokerCtx:
        gListDevicesTvNoArgCtxs.del(i)
        gListDevicesTvNoArgHandlers.del(i)
        break
  elif not reqChan.isNil():
    trace "clearProvider called from non-provider thread; " &
        "threadvar entries on provider thread are stale but harmless " &
        "(next setProvider will detect and clean them)",
          brokerType = "ListDevices"
  if not reqChan.isNil():
    var shutdownMsg = ListDevicesMtRequestMsg(isShutdown: true)
    reqChan[].sendSync(shutdownMsg)

proc clearProvider*(_: typedesc[ListDevices]) =
  clearProvider(ListDevices, DefaultBrokerContext)

proc cleanupApiRequestProvider_ListDevices(ctx: BrokerContext) =
  ListDevices.clearProvider(ctx)

type
  ListDevicesCResult* {.exportc.} = object
    error_message*: cstring
    devices*: pointer
    devices_count*: cint
proc encodeListDevicesToC(obj: ListDevices): ListDevicesCResult =
  let n = obj.devices.len
  result.devices_count = cint(n)
  if n > 0:
    let arr = cast[ptr UncheckedArray[DeviceInfoCItem]](allocShared(
        n * sizeof(DeviceInfoCItem)))
    for i in 0 ..< n:
      arr[i] = encodeDeviceInfoToCItem(obj.devices[i])
    result.devices = cast[pointer](arr)

proc free_list_devices_result(r: ptr ListDevicesCResult) {.
    exportc: "free_list_devices_result", cdecl, dynlib.} =
  if r.isNil:
    return
  if not r.error_message.isNil:
    freeCString(r.error_message)
  if r.devices_count > 0 and not r.devices.isNil:
    let arr = cast[ptr UncheckedArray[DeviceInfoCItem]](r.devices)
    for j in 0 ..< r.devices_count:
      if not arr[j].name.isNil:
        freeCString(arr[j].name)
      if not arr[j].deviceType.isNil:
        freeCString(arr[j].deviceType)
      if not arr[j].address.isNil:
        freeCString(arr[j].address)
    deallocShared(r.devices)

proc list_devices(ctx: uint32): ListDevicesCResult {.
    exportc: "list_devices", cdecl, dynlib.} =
  let brokerCtx = BrokerContext(ctx)
  let res = waitFor ListDevices.request(brokerCtx)
  if res.isOk():
    return encodeListDevicesToC(res.get())
  else:
    var errResult: ListDevicesCResult
    errResult.error_message = allocCStringCopy(res.error())
    return errResult
# ===== EventBroker(API): DeviceStatusChanged + shared RegisterEventListenerResult =====
## Flow:
## - EventBroker generates listener tables and emit/on/off helpers for the event itself.
## - The shared `RegisterEventListenerResult` request broker mediates cross-thread registration and teardown of foreign callbacks.
## - The exported C callbacks are adapted into Nim closures through generated registration handlers.
type
  DeviceStatusChanged* = object
    deviceId*: int64
    name*: string
    online*: bool
    timestampMs*: int64
  DeviceStatusChangedListener* = object
    id*: uint64
    threadId*: pointer       ## Thread that registered this listener (for validation on drop).
  DeviceStatusChangedListenerProc* = proc (event: DeviceStatusChanged): Future[
      void] {.async: (raises: []), gcsafe.}
  DeviceStatusChangedMtEventMsgKind {.pure.} = enum
    emkEvent,               ## Normal event delivery
    emkClearListeners,      ## Clear threadvar handlers, keep processLoop alive
    emkShutdown              ## Drain in-flight tasks and exit processLoop
  DeviceStatusChangedMtEventMsg = object
    kind: DeviceStatusChangedMtEventMsgKind
    event: DeviceStatusChanged
  DeviceStatusChangedMtEventBucket = object
    brokerCtx: BrokerContext
    eventChan: ptr AsyncChannel[DeviceStatusChangedMtEventMsg]
    threadId: pointer
    threadGen: uint64        ## Disambiguates reused threadvar addresses
    active: bool
    hasListeners: bool
var gDeviceStatusChangedMtBuckets: ptr UncheckedArray[
    DeviceStatusChangedMtEventBucket]
var gDeviceStatusChangedMtBucketCount: int
var gDeviceStatusChangedMtBucketCap: int
var gDeviceStatusChangedMtLock: Lock
var gDeviceStatusChangedMtInit: Atomic[int] ## 0 = uninitialised, 1 = initialising, 2 = ready.
                                            ## CAS(0→1) wins the race; losers spin until 2.
proc ensureInitDeviceStatusChangedMtBroker() =
  if gDeviceStatusChangedMtInit.load(moRelaxed) == 2:
    return
  var expected = 0
  if gDeviceStatusChangedMtInit.compareExchange(expected, 1,
      moAcquire, moRelaxed):
    initLock(gDeviceStatusChangedMtLock)
    gDeviceStatusChangedMtBucketCap = 4
    gDeviceStatusChangedMtBuckets = cast[ptr UncheckedArray[
        DeviceStatusChangedMtEventBucket]](createShared(
        DeviceStatusChangedMtEventBucket, gDeviceStatusChangedMtBucketCap))
    gDeviceStatusChangedMtBucketCount = 0
    gDeviceStatusChangedMtInit.store(2, moRelease)
  else:
    while gDeviceStatusChangedMtInit.load(moAcquire) != 2:
      discard

proc growDeviceStatusChangedMtBuckets() =
  ## Must be called under lock.
  let newCap = gDeviceStatusChangedMtBucketCap * 2
  let newBuf = cast[ptr UncheckedArray[
      DeviceStatusChangedMtEventBucket]](createShared(
      DeviceStatusChangedMtEventBucket, newCap))
  for i in 0 ..< gDeviceStatusChangedMtBucketCount:
    newBuf[i] = gDeviceStatusChangedMtBuckets[i]
  deallocShared(gDeviceStatusChangedMtBuckets)
  gDeviceStatusChangedMtBuckets = newBuf
  gDeviceStatusChangedMtBucketCap = newCap

var gDeviceStatusChangedTvListenerCtxs {.threadvar.}: seq[BrokerContext]
var gDeviceStatusChangedTvListenerHandlers {.threadvar.}: seq[
    Table[uint64, DeviceStatusChangedListenerProc]]
var gDeviceStatusChangedTvNextIds {.threadvar.}: seq[uint64]
proc notifyDeviceStatusChangedListener(callback: DeviceStatusChangedListenerProc;
                                       event: DeviceStatusChanged): Future[
    void] {.async: (raises: []).} =
  if callback.isNil():
    return
  try:
    await callback(event)
  except CatchableError:
    error "Failed to execute event listener", eventType = "DeviceStatusChanged",
          error = getCurrentExceptionMsg()

proc processLoopDeviceStatusChanged(eventChan: ptr AsyncChannel[
    DeviceStatusChangedMtEventMsg]; loopCtx: BrokerContext) {.
    async: (raises: []).} =
  var inFlight: seq[Future[void]] = @[]
  proc drainInFlight() {.async: (raises: []).} =
    for fut in inFlight:
      if not fut.finished():
        try:
          discard await withTimeout(fut, seconds(5))
        except CatchableError:
          discard
    inFlight.setLen(0)

  proc clearThreadvarListeners() =
    for i in 0 ..< gDeviceStatusChangedTvListenerCtxs.len:
      if gDeviceStatusChangedTvListenerCtxs[i] == loopCtx:
        gDeviceStatusChangedTvListenerHandlers[i].clear()
        gDeviceStatusChangedTvListenerCtxs.del(i)
        gDeviceStatusChangedTvListenerHandlers.del(i)
        gDeviceStatusChangedTvNextIds.del(i)
        break

  while true:
    let recvRes = catch do:
      await eventChan.recv()
    if recvRes.isErr():
      break
    let msg = recvRes.get()
    case msg.kind
    of DeviceStatusChangedMtEventMsgKind.emkShutdown:
      await drainInFlight()
      clearThreadvarListeners()
      break
    of DeviceStatusChangedMtEventMsgKind.emkClearListeners:
      await drainInFlight()
      clearThreadvarListeners()
    of DeviceStatusChangedMtEventMsgKind.emkEvent:
      var j = 0
      while j < inFlight.len:
        if inFlight[j].finished():
          try:
            await inFlight[j]
          except CatchableError:
            discard
          inFlight.del(j)
        else:
          inc j
      var idx = -1
      for i in 0 ..< gDeviceStatusChangedTvListenerCtxs.len:
        if gDeviceStatusChangedTvListenerCtxs[i] == loopCtx:
          idx = i
          break
      if idx >= 0:
        var callbacks: seq[DeviceStatusChangedListenerProc] = @[]
        for cb in gDeviceStatusChangedTvListenerHandlers[
            idx].values:
          callbacks.add(cb)
        for cb in callbacks:
          let fut = notifyDeviceStatusChangedListener(cb,
              msg.event)
          inFlight.add(fut)

proc listenDeviceStatusChangedMtImpl(brokerCtx: BrokerContext;
    handler: DeviceStatusChangedListenerProc): Result[
    DeviceStatusChangedListener, string] =
  if handler.isNil():
    return err("Must provide a non-nil event handler")
  ensureInitDeviceStatusChangedMtBroker()
  var tvIdx = -1
  for i in 0 ..< gDeviceStatusChangedTvListenerCtxs.len:
    if gDeviceStatusChangedTvListenerCtxs[i] ==
        brokerCtx:
      tvIdx = i
      break
  if tvIdx < 0:
    gDeviceStatusChangedTvListenerCtxs.add(brokerCtx)
    gDeviceStatusChangedTvListenerHandlers.add(
        initTable[uint64, DeviceStatusChangedListenerProc]())
    gDeviceStatusChangedTvNextIds.add(1'u64)
    tvIdx = gDeviceStatusChangedTvListenerCtxs.len - 1
  if gDeviceStatusChangedTvNextIds[tvIdx] == high(uint64):
    return err("Cannot add more listeners: ID space exhausted")
  let newId = gDeviceStatusChangedTvNextIds[tvIdx]
  gDeviceStatusChangedTvNextIds[tvIdx] += 1
  gDeviceStatusChangedTvListenerHandlers[tvIdx][newId] = handler
  let myThreadId = currentMtThreadId()
  let myThreadGen = currentMtThreadGen()
  var bucketExists = false
  var spawnChan: ptr AsyncChannel[DeviceStatusChangedMtEventMsg]
  withLock(gDeviceStatusChangedMtLock):
    for i in 0 ..< gDeviceStatusChangedMtBucketCount:
      if gDeviceStatusChangedMtBuckets[i].brokerCtx ==
          brokerCtx and
          gDeviceStatusChangedMtBuckets[i].threadId ==
          myThreadId and
          gDeviceStatusChangedMtBuckets[i].threadGen ==
          myThreadGen:
        gDeviceStatusChangedMtBuckets[i].hasListeners = true
        bucketExists = true
        break
    if not bucketExists:
      if gDeviceStatusChangedMtBucketCount >= gDeviceStatusChangedMtBucketCap:
        growDeviceStatusChangedMtBuckets()
      let chan = cast[ptr AsyncChannel[DeviceStatusChangedMtEventMsg]](createShared(
          AsyncChannel[DeviceStatusChangedMtEventMsg], 1))
      discard chan[].open()
      let idx = gDeviceStatusChangedMtBucketCount
      gDeviceStatusChangedMtBuckets[idx] = DeviceStatusChangedMtEventBucket(
          brokerCtx: brokerCtx, eventChan: chan,
          threadId: myThreadId, threadGen: myThreadGen,
          active: true, hasListeners: true)
      gDeviceStatusChangedMtBucketCount += 1
      spawnChan = chan
  if not bucketExists and not spawnChan.isNil:
    asyncSpawn processLoopDeviceStatusChanged(spawnChan,
        brokerCtx)
  return ok(DeviceStatusChangedListener(id: newId,
                                        threadId: myThreadId))

proc listen*(_: typedesc[DeviceStatusChanged];
             handler: DeviceStatusChangedListenerProc): Result[
    DeviceStatusChangedListener, string] =
  return listenDeviceStatusChangedMtImpl(DefaultBrokerContext,
      handler)

proc listen*(_: typedesc[DeviceStatusChanged];
             brokerCtx: BrokerContext;
             handler: DeviceStatusChangedListenerProc): Result[
    DeviceStatusChangedListener, string] =
  return listenDeviceStatusChangedMtImpl(brokerCtx,
      handler)

proc emitDeviceStatusChangedMtImpl(brokerCtx: BrokerContext;
                                   event: DeviceStatusChanged) {.
    async: (raises: []).} =
  ensureInitDeviceStatusChangedMtBroker()
  when compiles(event.isNil()):
    if event.isNil():
      error "Cannot emit uninitialized event object",
            eventType = "DeviceStatusChanged"
      return
  type
    EvTarget = object
      eventChan: ptr AsyncChannel[DeviceStatusChangedMtEventMsg]
      isSameThread: bool
  var targets: seq[EvTarget] = @[]
  let myThreadId = currentMtThreadId()
  withLock(gDeviceStatusChangedMtLock):
    for i in 0 ..< gDeviceStatusChangedMtBucketCount:
      if gDeviceStatusChangedMtBuckets[i].brokerCtx ==
          brokerCtx and
          gDeviceStatusChangedMtBuckets[i].active and
          gDeviceStatusChangedMtBuckets[i].hasListeners:
        targets.add(EvTarget(eventChan: gDeviceStatusChangedMtBuckets[
            i].eventChan, isSameThread: gDeviceStatusChangedMtBuckets[
            i].threadId ==
            myThreadId))
  if targets.len == 0:
    return
  for target in targets:
    if target.isSameThread:
      var idx = -1
      for i in 0 ..< gDeviceStatusChangedTvListenerCtxs.len:
        if gDeviceStatusChangedTvListenerCtxs[i] ==
            brokerCtx:
          idx = i
          break
      if idx >= 0:
        var callbacks: seq[DeviceStatusChangedListenerProc] = @[]
        for cb in gDeviceStatusChangedTvListenerHandlers[
            idx].values:
          callbacks.add(cb)
        for cb in callbacks:
          asyncSpawn notifyDeviceStatusChangedListener(cb,
              event)
    else:
      let msg = DeviceStatusChangedMtEventMsg(
          kind: DeviceStatusChangedMtEventMsgKind.emkEvent,
          event: event)
      target.eventChan[].sendSync(msg)

proc emit*(event: DeviceStatusChanged) {.async: (raises: []).} =
  await emitDeviceStatusChangedMtImpl(DefaultBrokerContext, event)

proc emit*(_: typedesc[DeviceStatusChanged];
           event: DeviceStatusChanged) {.async: (raises: []).} =
  await emitDeviceStatusChangedMtImpl(DefaultBrokerContext, event)

proc emit*(_: typedesc[DeviceStatusChanged];
           brokerCtx: BrokerContext;
           event: DeviceStatusChanged) {.async: (raises: []).} =
  await emitDeviceStatusChangedMtImpl(brokerCtx, event)

proc emit*(_: typedesc[DeviceStatusChanged]; deviceId: int64; name: string;
           online: bool; timestampMs: int64) {.async: (raises: []).} =
  await emitDeviceStatusChangedMtImpl(DefaultBrokerContext, DeviceStatusChanged(
      deviceId: deviceId, name: name, online: online, timestampMs: timestampMs))

proc emit*(_: typedesc[DeviceStatusChanged]; brokerCtx: BrokerContext;
           deviceId: int64; name: string; online: bool; timestampMs: int64) {.
    async: (raises: []).} =
  await emitDeviceStatusChangedMtImpl(brokerCtx, DeviceStatusChanged(
      deviceId: deviceId, name: name, online: online, timestampMs: timestampMs))

proc dropDeviceStatusChangedMtListenerImpl(brokerCtx: BrokerContext;
    handle: DeviceStatusChangedListener) =
  if handle.id == 0'u64:
    return
  if handle.threadId != currentMtThreadId():
    error "dropListener called from wrong thread",
          eventType = "DeviceStatusChanged",
          handleThread = repr(handle.threadId),
          currentThread = repr(currentMtThreadId())
    return
  var tvIdx = -1
  for i in 0 ..< gDeviceStatusChangedTvListenerCtxs.len:
    if gDeviceStatusChangedTvListenerCtxs[i] ==
        brokerCtx:
      tvIdx = i
      break
  if tvIdx < 0:
    return
  gDeviceStatusChangedTvListenerHandlers[tvIdx].del(
      handle.id)
  if gDeviceStatusChangedTvListenerHandlers[tvIdx].len == 0:
    gDeviceStatusChangedTvListenerCtxs.del(tvIdx)
    gDeviceStatusChangedTvListenerHandlers.del(tvIdx)
    gDeviceStatusChangedTvNextIds.del(tvIdx)
    let myThreadId = currentMtThreadId()
    let myThreadGen = currentMtThreadGen()
    withLock(gDeviceStatusChangedMtLock):
      for i in 0 ..< gDeviceStatusChangedMtBucketCount:
        if gDeviceStatusChangedMtBuckets[i].brokerCtx ==
            brokerCtx and
            gDeviceStatusChangedMtBuckets[i].threadId ==
            myThreadId and
            gDeviceStatusChangedMtBuckets[i].threadGen ==
            myThreadGen:
          gDeviceStatusChangedMtBuckets[i].hasListeners = false
          break

proc dropAllDeviceStatusChangedMtListenersImpl(
    brokerCtx: BrokerContext) =
  ensureInitDeviceStatusChangedMtBroker()
  let myThreadId = currentMtThreadId()
  var chansToClear: seq[ptr AsyncChannel[
      DeviceStatusChangedMtEventMsg]] = @[]
  withLock(gDeviceStatusChangedMtLock):
    for i in 0 ..< gDeviceStatusChangedMtBucketCount:
      if gDeviceStatusChangedMtBuckets[i].brokerCtx ==
          brokerCtx and
          gDeviceStatusChangedMtBuckets[i].hasListeners:
        gDeviceStatusChangedMtBuckets[i].hasListeners = false
        if gDeviceStatusChangedMtBuckets[i].threadId !=
            myThreadId:
          chansToClear.add(gDeviceStatusChangedMtBuckets[i].eventChan)
  var tvIdx = -1
  for i in 0 ..< gDeviceStatusChangedTvListenerCtxs.len:
    if gDeviceStatusChangedTvListenerCtxs[i] ==
        brokerCtx:
      tvIdx = i
      break
  if tvIdx >= 0:
    gDeviceStatusChangedTvListenerHandlers[tvIdx].clear()
    gDeviceStatusChangedTvListenerCtxs.del(tvIdx)
    gDeviceStatusChangedTvListenerHandlers.del(tvIdx)
    gDeviceStatusChangedTvNextIds.del(tvIdx)
  for chan in chansToClear:
    chan[].sendSync(DeviceStatusChangedMtEventMsg(
        kind: DeviceStatusChangedMtEventMsgKind.emkClearListeners))

proc dropListener*(_: typedesc[DeviceStatusChanged];
                   handle: DeviceStatusChangedListener) =
  dropDeviceStatusChangedMtListenerImpl(DefaultBrokerContext, handle)

proc dropListener*(_: typedesc[DeviceStatusChanged];
                   brokerCtx: BrokerContext;
                   handle: DeviceStatusChangedListener) =
  dropDeviceStatusChangedMtListenerImpl(brokerCtx, handle)

proc dropAllListeners*(_: typedesc[DeviceStatusChanged]) =
  dropAllDeviceStatusChangedMtListenersImpl(DefaultBrokerContext)

proc dropAllListeners*(_: typedesc[DeviceStatusChanged];
                       brokerCtx: BrokerContext) =
  dropAllDeviceStatusChangedMtListenersImpl(brokerCtx)

type
  RegisterEventListenerResult* = object
    handle*: uint64
    success*: bool
  RegisterEventListenerResultProviderWithArgs = proc (action: int32;
      eventTypeId: int32; callbackPtr: pointer; listenerHandle: uint64): Future[
      Result[RegisterEventListenerResult, string]] {.async.}
  RegisterEventListenerResultMtRequestMsg = object
    isShutdown: bool
    requestKind: int
    action: int32
    eventTypeId: int32
    callbackPtr: pointer
    listenerHandle: uint64
    responseChan: ptr AsyncChannel[Result[RegisterEventListenerResult, string]]
  RegisterEventListenerResultMtBucket = object
    brokerCtx: BrokerContext
    requestChan: ptr AsyncChannel[RegisterEventListenerResultMtRequestMsg]
    threadId: pointer
    threadGen: uint64
var gRegisterEventListenerResultMtBuckets: ptr UncheckedArray[
    RegisterEventListenerResultMtBucket]
var gRegisterEventListenerResultMtBucketCount: int
var gRegisterEventListenerResultMtBucketCap: int
var gRegisterEventListenerResultMtLock: Lock
var gRegisterEventListenerResultMtInit: Atomic[int] ## 0 = uninitialised, 1 = initialising, 2 = ready.
                                                    ## CAS(0→1) wins the race; losers spin until 2.
proc ensureInitRegisterEventListenerResultMtBroker() =
  if gRegisterEventListenerResultMtInit.load(moRelaxed) == 2:
    return
  var expected = 0
  if gRegisterEventListenerResultMtInit.compareExchange(expected, 1,
      moAcquire, moRelaxed):
    initLock(gRegisterEventListenerResultMtLock)
    gRegisterEventListenerResultMtBucketCap = 4
    gRegisterEventListenerResultMtBuckets = cast[ptr UncheckedArray[
        RegisterEventListenerResultMtBucket]](createShared(
        RegisterEventListenerResultMtBucket,
        gRegisterEventListenerResultMtBucketCap))
    gRegisterEventListenerResultMtBucketCount = 0
    gRegisterEventListenerResultMtInit.store(2, moRelease)
  else:
    while gRegisterEventListenerResultMtInit.load(moAcquire) != 2:
      discard

proc growRegisterEventListenerResultMtBuckets() =
  ## Must be called under lock.
  let newCap = gRegisterEventListenerResultMtBucketCap * 2
  let newBuf = cast[ptr UncheckedArray[
      RegisterEventListenerResultMtBucket]](createShared(
      RegisterEventListenerResultMtBucket, newCap))
  for i in 0 ..< gRegisterEventListenerResultMtBucketCount:
    newBuf[i] = gRegisterEventListenerResultMtBuckets[
        i]
  deallocShared(gRegisterEventListenerResultMtBuckets)
  gRegisterEventListenerResultMtBuckets = newBuf
  gRegisterEventListenerResultMtBucketCap = newCap

var gRegisterEventListenerResultMtRequestTimeout*: Duration = seconds(5) ## Default timeout for cross-thread requests. Same-thread requests
                                                                         ## bypass this (they call the provider directly).
                                                                         ## NOTE: Set during initialization before spawning worker threads.
                                                                         ## Reading from multiple threads is safe on x86-64 (aligned int64),
                                                                         ## but concurrent writes are not guaranteed atomic on all platforms.
proc setRequestTimeout*(_: typedesc[RegisterEventListenerResult];
                        timeout: Duration) =
  ## Set the cross-thread request timeout for this broker type.
  ## Call this during initialization before spawning worker threads.
  gRegisterEventListenerResultMtRequestTimeout = timeout

proc requestTimeout*(_: typedesc[RegisterEventListenerResult]): Duration =
  ## Get the current cross-thread request timeout for this broker type.
  gRegisterEventListenerResultMtRequestTimeout

var gRegisterEventListenerResultTvWithArgCtxs {.threadvar.}: seq[BrokerContext]
var gRegisterEventListenerResultTvWithArgHandlers {.threadvar.}: seq[
    RegisterEventListenerResultProviderWithArgs]
proc processLoopRegisterEventListenerResult(
    requestChan: ptr AsyncChannel[RegisterEventListenerResultMtRequestMsg];
    loopCtx: BrokerContext) {.async: (raises: []).} =
  while true:
    let recvRes = catch do:
      await requestChan.recv()
    if recvRes.isErr():
      break
    let msg = recvRes.get()
    if msg.isShutdown:
      break
    if msg.requestKind == 1:
      var handler1: RegisterEventListenerResultProviderWithArgs
      for i in 0 ..< gRegisterEventListenerResultTvWithArgCtxs.len:
        if gRegisterEventListenerResultTvWithArgCtxs[i] ==
            loopCtx:
          handler1 = gRegisterEventListenerResultTvWithArgHandlers[i]
          break
      if handler1.isNil():
        msg.responseChan[].sendSync(err(Result[RegisterEventListenerResult,
            string], "RequestBroker(" & "RegisterEventListenerResult" &
            "): no provider registered for input signature"))
      else:
        let catchedRes = catch do:
          await handler1(msg.action, msg.eventTypeId, msg.callbackPtr,
                         msg.listenerHandle)
        if catchedRes.isErr():
          msg.responseChan[].sendSync(err(
              Result[RegisterEventListenerResult, string], "RequestBroker(" &
              "RegisterEventListenerResult" &
              "): provider threw exception: " &
              catchedRes.error.msg))
        else:
          let providerRes = catchedRes.get()
          if providerRes.isOk():
            let resultValue = providerRes.get()
            when compiles(resultValue.isNil()):
              if resultValue.isNil():
                msg.responseChan[].sendSync(err(
                    Result[RegisterEventListenerResult, string], "RequestBroker(" &
                    "RegisterEventListenerResult" &
                    "): provider returned nil result"))
                continue
          msg.responseChan[].sendSync(providerRes)

proc setProvider*(_: typedesc[RegisterEventListenerResult]; handler: RegisterEventListenerResultProviderWithArgs): Result[
    void, string] =
  ensureInitRegisterEventListenerResultMtBroker()
  let myThreadGen = currentMtThreadGen()
  for i in 0 ..< gRegisterEventListenerResultTvWithArgCtxs.len:
    if gRegisterEventListenerResultTvWithArgCtxs[i] ==
        DefaultBrokerContext:
      var isStale = true
      withLock(gRegisterEventListenerResultMtLock):
        for j in 0 ..< gRegisterEventListenerResultMtBucketCount:
          if gRegisterEventListenerResultMtBuckets[j].brokerCtx ==
              DefaultBrokerContext and
              gRegisterEventListenerResultMtBuckets[j].threadId ==
              currentMtThreadId() and
              gRegisterEventListenerResultMtBuckets[j].threadGen ==
              myThreadGen:
            isStale = false
            break
      if isStale:
        gRegisterEventListenerResultTvWithArgCtxs.del(i)
        gRegisterEventListenerResultTvWithArgHandlers.del(i)
        break
      else:
        return err("Provider already set")
  gRegisterEventListenerResultTvWithArgCtxs.add(DefaultBrokerContext)
  gRegisterEventListenerResultTvWithArgHandlers.add(handler)
  var spawnChan: ptr AsyncChannel[
      RegisterEventListenerResultMtRequestMsg]
  withLock(gRegisterEventListenerResultMtLock):
    for i in 0 ..< gRegisterEventListenerResultMtBucketCount:
      if gRegisterEventListenerResultMtBuckets[i].brokerCtx ==
          DefaultBrokerContext:
        if gRegisterEventListenerResultMtBuckets[i].threadId ==
            currentMtThreadId() and
            gRegisterEventListenerResultMtBuckets[i].threadGen ==
            myThreadGen:
          return ok()
        else:
          gRegisterEventListenerResultTvWithArgCtxs.setLen(
              gRegisterEventListenerResultTvWithArgCtxs.len - 1)
          gRegisterEventListenerResultTvWithArgHandlers.setLen(
              gRegisterEventListenerResultTvWithArgHandlers.len - 1)
          return err("RequestBroker(" & "RegisterEventListenerResult" &
              "): provider already set from another thread")
    if gRegisterEventListenerResultMtBucketCount >=
        gRegisterEventListenerResultMtBucketCap:
      growRegisterEventListenerResultMtBuckets()
    spawnChan = cast[ptr AsyncChannel[
        RegisterEventListenerResultMtRequestMsg]](createShared(
        AsyncChannel[RegisterEventListenerResultMtRequestMsg], 1))
    discard spawnChan[].open()
    let idx = gRegisterEventListenerResultMtBucketCount
    gRegisterEventListenerResultMtBuckets[idx] = RegisterEventListenerResultMtBucket(
        brokerCtx: DefaultBrokerContext, requestChan: spawnChan,
        threadId: currentMtThreadId(), threadGen: myThreadGen)
    gRegisterEventListenerResultMtBucketCount += 1
  if not spawnChan.isNil:
    asyncSpawn processLoopRegisterEventListenerResult(spawnChan,
        DefaultBrokerContext)
  return ok()

proc setProvider*(_: typedesc[RegisterEventListenerResult];
                  brokerCtx: BrokerContext; handler: RegisterEventListenerResultProviderWithArgs): Result[
    void, string] =
  if brokerCtx == DefaultBrokerContext:
    return setProvider(RegisterEventListenerResult, handler)
  ensureInitRegisterEventListenerResultMtBroker()
  let myThreadGen = currentMtThreadGen()
  for i in 0 ..< gRegisterEventListenerResultTvWithArgCtxs.len:
    if gRegisterEventListenerResultTvWithArgCtxs[i] ==
        brokerCtx:
      var isStale = true
      withLock(gRegisterEventListenerResultMtLock):
        for j in 0 ..< gRegisterEventListenerResultMtBucketCount:
          if gRegisterEventListenerResultMtBuckets[j].brokerCtx ==
              brokerCtx and
              gRegisterEventListenerResultMtBuckets[j].threadId ==
              currentMtThreadId() and
              gRegisterEventListenerResultMtBuckets[j].threadGen ==
              myThreadGen:
            isStale = false
            break
      if isStale:
        gRegisterEventListenerResultTvWithArgCtxs.del(i)
        gRegisterEventListenerResultTvWithArgHandlers.del(i)
        break
      else:
        return err("RequestBroker(" & "RegisterEventListenerResult" &
            "): provider already set for broker context " &
            $brokerCtx)
  gRegisterEventListenerResultTvWithArgCtxs.add(brokerCtx)
  gRegisterEventListenerResultTvWithArgHandlers.add(handler)
  var spawnChan: ptr AsyncChannel[
      RegisterEventListenerResultMtRequestMsg]
  withLock(gRegisterEventListenerResultMtLock):
    for i in 0 ..< gRegisterEventListenerResultMtBucketCount:
      if gRegisterEventListenerResultMtBuckets[i].brokerCtx ==
          brokerCtx:
        if gRegisterEventListenerResultMtBuckets[i].threadId ==
            currentMtThreadId() and
            gRegisterEventListenerResultMtBuckets[i].threadGen ==
            myThreadGen:
          return ok()
        else:
          gRegisterEventListenerResultTvWithArgCtxs.setLen(
              gRegisterEventListenerResultTvWithArgCtxs.len - 1)
          gRegisterEventListenerResultTvWithArgHandlers.setLen(
              gRegisterEventListenerResultTvWithArgHandlers.len - 1)
          return err("RequestBroker(" & "RegisterEventListenerResult" &
              "): provider already set from another thread for context " &
              $brokerCtx)
    if gRegisterEventListenerResultMtBucketCount >=
        gRegisterEventListenerResultMtBucketCap:
      growRegisterEventListenerResultMtBuckets()
    spawnChan = cast[ptr AsyncChannel[
        RegisterEventListenerResultMtRequestMsg]](createShared(
        AsyncChannel[RegisterEventListenerResultMtRequestMsg], 1))
    discard spawnChan[].open()
    let idx = gRegisterEventListenerResultMtBucketCount
    gRegisterEventListenerResultMtBuckets[idx] = RegisterEventListenerResultMtBucket(
        brokerCtx: brokerCtx, requestChan: spawnChan,
        threadId: currentMtThreadId(), threadGen: myThreadGen)
    gRegisterEventListenerResultMtBucketCount += 1
  if not spawnChan.isNil:
    asyncSpawn processLoopRegisterEventListenerResult(spawnChan,
        brokerCtx)
  return ok()

proc request*(_: typedesc[RegisterEventListenerResult]): Future[
    Result[RegisterEventListenerResult, string]] {.async: (raises: []).} =
  return err("RequestBroker(" & "RegisterEventListenerResult" &
      "): no zero-arg provider registered")

proc request*(_: typedesc[RegisterEventListenerResult]; action: int32;
              eventTypeId: int32; callbackPtr: pointer; listenerHandle: uint64): Future[
    Result[RegisterEventListenerResult, string]] {.async: (raises: []).} =
  return await request(RegisterEventListenerResult, DefaultBrokerContext,
                       action, eventTypeId, callbackPtr, listenerHandle)

proc request*(_: typedesc[RegisterEventListenerResult];
              brokerCtx: BrokerContext; action: int32; eventTypeId: int32;
              callbackPtr: pointer; listenerHandle: uint64): Future[
    Result[RegisterEventListenerResult, string]] {.async: (raises: []).} =
  ensureInitRegisterEventListenerResultMtBroker()
  var reqChan: ptr AsyncChannel[RegisterEventListenerResultMtRequestMsg]
  var sameThread = false
  let myThreadGen = currentMtThreadGen()
  withLock(gRegisterEventListenerResultMtLock):
    for i in 0 ..< gRegisterEventListenerResultMtBucketCount:
      if gRegisterEventListenerResultMtBuckets[i].brokerCtx ==
          brokerCtx:
        if gRegisterEventListenerResultMtBuckets[i].threadId ==
            currentMtThreadId() and
            gRegisterEventListenerResultMtBuckets[i].threadGen ==
            myThreadGen:
          sameThread = true
        else:
          reqChan = gRegisterEventListenerResultMtBuckets[i].requestChan
        break
  if sameThread:
    var provider: RegisterEventListenerResultProviderWithArgs
    for i in 0 ..< gRegisterEventListenerResultTvWithArgCtxs.len:
      if gRegisterEventListenerResultTvWithArgCtxs[i] ==
          brokerCtx:
        provider = gRegisterEventListenerResultTvWithArgHandlers[
            i]
        break
    if provider.isNil():
      return err("RequestBroker(" & "RegisterEventListenerResult" &
          "): no provider registered for input signature")
    let catchedRes = catch do:
      await provider(action, eventTypeId, callbackPtr, listenerHandle)
    if catchedRes.isErr():
      return err("RequestBroker(" & "RegisterEventListenerResult" &
          "): provider threw exception: " &
          catchedRes.error.msg)
    let providerRes = catchedRes.get()
    if providerRes.isOk():
      let resultValue = providerRes.get()
      when compiles(resultValue.isNil()):
        if resultValue.isNil():
          return err("RequestBroker(" & "RegisterEventListenerResult" &
              "): provider returned nil result")
    return providerRes
  else:
    if reqChan.isNil():
      return err("RequestBroker(" & "RegisterEventListenerResult" &
          "): no provider registered for broker context " &
          $brokerCtx)
    let respChan = cast[ptr AsyncChannel[
        Result[RegisterEventListenerResult, string]]](createShared(
        AsyncChannel[Result[RegisterEventListenerResult, string]], 1))
    discard respChan[].open()
    var msg = RegisterEventListenerResultMtRequestMsg(
        isShutdown: false, requestKind: 1, action: action,
        eventTypeId: eventTypeId, callbackPtr: callbackPtr,
        listenerHandle: listenerHandle, responseChan: respChan)
    reqChan[].sendSync(msg)
    let recvFut = respChan.recv()
    let completedRes = catch do:
      await withTimeout(recvFut,
                        gRegisterEventListenerResultMtRequestTimeout)
    if completedRes.isErr():
      return err("RequestBroker(" & "RegisterEventListenerResult" &
          "): recv failed: " &
          completedRes.error.msg)
    if not completedRes.get():
      return err("RequestBroker(" & "RegisterEventListenerResult" &
          "): cross-thread request timed out after " &
          $gRegisterEventListenerResultMtRequestTimeout)
    respChan[].close()
    deallocShared(respChan)
    let recvRes = catch do:
      recvFut.read()
    if recvRes.isErr():
      return err("RequestBroker(" & "RegisterEventListenerResult" &
          "): recv failed: " &
          recvRes.error.msg)
    return recvRes.get()

proc clearProvider*(_: typedesc[RegisterEventListenerResult];
                    brokerCtx: BrokerContext) =
  ensureInitRegisterEventListenerResultMtBroker()
  var reqChan: ptr AsyncChannel[
      RegisterEventListenerResultMtRequestMsg]
  var isProviderThread = false
  let myThreadGen = currentMtThreadGen()
  withLock(gRegisterEventListenerResultMtLock):
    var foundIdx = -1
    for i in 0 ..< gRegisterEventListenerResultMtBucketCount:
      if gRegisterEventListenerResultMtBuckets[i].brokerCtx ==
          brokerCtx:
        reqChan = gRegisterEventListenerResultMtBuckets[i].requestChan
        isProviderThread = (gRegisterEventListenerResultMtBuckets[
            i].threadId ==
            currentMtThreadId() and
            gRegisterEventListenerResultMtBuckets[i].threadGen ==
            myThreadGen)
        foundIdx = i
        break
    if foundIdx >= 0:
      for i in foundIdx ..<
          gRegisterEventListenerResultMtBucketCount - 1:
        gRegisterEventListenerResultMtBuckets[i] = gRegisterEventListenerResultMtBuckets[
            i + 1]
      gRegisterEventListenerResultMtBucketCount -= 1
  if isProviderThread:
    for i in countdown(gRegisterEventListenerResultTvWithArgCtxs.len -
        1, 0):
      if gRegisterEventListenerResultTvWithArgCtxs[i] ==
          brokerCtx:
        gRegisterEventListenerResultTvWithArgCtxs.del(i)
        gRegisterEventListenerResultTvWithArgHandlers.del(i)
        break
  elif not reqChan.isNil():
    trace "clearProvider called from non-provider thread; " &
        "threadvar entries on provider thread are stale but harmless " &
        "(next setProvider will detect and clean them)",
          brokerType = "RegisterEventListenerResult"
  if not reqChan.isNil():
    var shutdownMsg = RegisterEventListenerResultMtRequestMsg(
        isShutdown: true)
    reqChan[].sendSync(shutdownMsg)

proc clearProvider*(_: typedesc[RegisterEventListenerResult]) =
  clearProvider(RegisterEventListenerResult, DefaultBrokerContext)

type
  DeviceStatusChanged* = object
    deviceId*: int64
    name*: string
    online*: bool
    timestampMs*: int64
  DeviceStatusChangedListener* = object
    id*: uint64
    threadId*: pointer       ## Thread that registered this listener (for validation on drop).
  DeviceStatusChangedListenerProc* = proc (event: DeviceStatusChanged): Future[
      void] {.async: (raises: []), gcsafe.}
  DeviceStatusChangedMtEventMsgKind {.pure.} = enum
    emkEvent,               ## Normal event delivery
    emkClearListeners,      ## Clear threadvar handlers, keep processLoop alive
    emkShutdown              ## Drain in-flight tasks and exit processLoop
  DeviceStatusChangedMtEventMsg = object
    kind: DeviceStatusChangedMtEventMsgKind
    event: DeviceStatusChanged
  DeviceStatusChangedMtEventBucket = object
    brokerCtx: BrokerContext
    eventChan: ptr AsyncChannel[DeviceStatusChangedMtEventMsg]
    threadId: pointer
    threadGen: uint64        ## Disambiguates reused threadvar addresses
    active: bool
    hasListeners: bool
var gDeviceStatusChangedMtBuckets: ptr UncheckedArray[
    DeviceStatusChangedMtEventBucket]
var gDeviceStatusChangedMtBucketCount: int
var gDeviceStatusChangedMtBucketCap: int
var gDeviceStatusChangedMtLock: Lock
var gDeviceStatusChangedMtInit: Atomic[int] ## 0 = uninitialised, 1 = initialising, 2 = ready.
                                            ## CAS(0→1) wins the race; losers spin until 2.
proc ensureInitDeviceStatusChangedMtBroker() =
  if gDeviceStatusChangedMtInit.load(moRelaxed) == 2:
    return
  var expected = 0
  if gDeviceStatusChangedMtInit.compareExchange(expected, 1,
      moAcquire, moRelaxed):
    initLock(gDeviceStatusChangedMtLock)
    gDeviceStatusChangedMtBucketCap = 4
    gDeviceStatusChangedMtBuckets = cast[ptr UncheckedArray[
        DeviceStatusChangedMtEventBucket]](createShared(
        DeviceStatusChangedMtEventBucket, gDeviceStatusChangedMtBucketCap))
    gDeviceStatusChangedMtBucketCount = 0
    gDeviceStatusChangedMtInit.store(2, moRelease)
  else:
    while gDeviceStatusChangedMtInit.load(moAcquire) != 2:
      discard

proc growDeviceStatusChangedMtBuckets() =
  ## Must be called under lock.
  let newCap = gDeviceStatusChangedMtBucketCap * 2
  let newBuf = cast[ptr UncheckedArray[
      DeviceStatusChangedMtEventBucket]](createShared(
      DeviceStatusChangedMtEventBucket, newCap))
  for i in 0 ..< gDeviceStatusChangedMtBucketCount:
    newBuf[i] = gDeviceStatusChangedMtBuckets[i]
  deallocShared(gDeviceStatusChangedMtBuckets)
  gDeviceStatusChangedMtBuckets = newBuf
  gDeviceStatusChangedMtBucketCap = newCap

var gDeviceStatusChangedTvListenerCtxs {.threadvar.}: seq[BrokerContext]
var gDeviceStatusChangedTvListenerHandlers {.threadvar.}: seq[
    Table[uint64, DeviceStatusChangedListenerProc]]
var gDeviceStatusChangedTvNextIds {.threadvar.}: seq[uint64]
proc notifyDeviceStatusChangedListener(callback: DeviceStatusChangedListenerProc;
                                       event: DeviceStatusChanged): Future[
    void] {.async: (raises: []).} =
  if callback.isNil():
    return
  try:
    await callback(event)
  except CatchableError:
    error "Failed to execute event listener", eventType = "DeviceStatusChanged",
          error = getCurrentExceptionMsg()

proc processLoopDeviceStatusChanged(eventChan: ptr AsyncChannel[
    DeviceStatusChangedMtEventMsg]; loopCtx: BrokerContext) {.
    async: (raises: []).} =
  var inFlight: seq[Future[void]] = @[]
  proc drainInFlight() {.async: (raises: []).} =
    for fut in inFlight:
      if not fut.finished():
        try:
          discard await withTimeout(fut, seconds(5))
        except CatchableError:
          discard
    inFlight.setLen(0)

  proc clearThreadvarListeners() =
    for i in 0 ..< gDeviceStatusChangedTvListenerCtxs.len:
      if gDeviceStatusChangedTvListenerCtxs[i] == loopCtx:
        gDeviceStatusChangedTvListenerHandlers[i].clear()
        gDeviceStatusChangedTvListenerCtxs.del(i)
        gDeviceStatusChangedTvListenerHandlers.del(i)
        gDeviceStatusChangedTvNextIds.del(i)
        break

  while true:
    let recvRes = catch do:
      await eventChan.recv()
    if recvRes.isErr():
      break
    let msg = recvRes.get()
    case msg.kind
    of DeviceStatusChangedMtEventMsgKind.emkShutdown:
      await drainInFlight()
      clearThreadvarListeners()
      break
    of DeviceStatusChangedMtEventMsgKind.emkClearListeners:
      await drainInFlight()
      clearThreadvarListeners()
    of DeviceStatusChangedMtEventMsgKind.emkEvent:
      var j = 0
      while j < inFlight.len:
        if inFlight[j].finished():
          try:
            await inFlight[j]
          except CatchableError:
            discard
          inFlight.del(j)
        else:
          inc j
      var idx = -1
      for i in 0 ..< gDeviceStatusChangedTvListenerCtxs.len:
        if gDeviceStatusChangedTvListenerCtxs[i] == loopCtx:
          idx = i
          break
      if idx >= 0:
        var callbacks: seq[DeviceStatusChangedListenerProc] = @[]
        for cb in gDeviceStatusChangedTvListenerHandlers[
            idx].values:
          callbacks.add(cb)
        for cb in callbacks:
          let fut = notifyDeviceStatusChangedListener(cb,
              msg.event)
          inFlight.add(fut)

proc listenDeviceStatusChangedMtImpl(brokerCtx: BrokerContext;
    handler: DeviceStatusChangedListenerProc): Result[
    DeviceStatusChangedListener, string] =
  if handler.isNil():
    return err("Must provide a non-nil event handler")
  ensureInitDeviceStatusChangedMtBroker()
  var tvIdx = -1
  for i in 0 ..< gDeviceStatusChangedTvListenerCtxs.len:
    if gDeviceStatusChangedTvListenerCtxs[i] ==
        brokerCtx:
      tvIdx = i
      break
  if tvIdx < 0:
    gDeviceStatusChangedTvListenerCtxs.add(brokerCtx)
    gDeviceStatusChangedTvListenerHandlers.add(
        initTable[uint64, DeviceStatusChangedListenerProc]())
    gDeviceStatusChangedTvNextIds.add(1'u64)
    tvIdx = gDeviceStatusChangedTvListenerCtxs.len - 1
  if gDeviceStatusChangedTvNextIds[tvIdx] == high(uint64):
    return err("Cannot add more listeners: ID space exhausted")
  let newId = gDeviceStatusChangedTvNextIds[tvIdx]
  gDeviceStatusChangedTvNextIds[tvIdx] += 1
  gDeviceStatusChangedTvListenerHandlers[tvIdx][newId] = handler
  let myThreadId = currentMtThreadId()
  let myThreadGen = currentMtThreadGen()
  var bucketExists = false
  var spawnChan: ptr AsyncChannel[DeviceStatusChangedMtEventMsg]
  withLock(gDeviceStatusChangedMtLock):
    for i in 0 ..< gDeviceStatusChangedMtBucketCount:
      if gDeviceStatusChangedMtBuckets[i].brokerCtx ==
          brokerCtx and
          gDeviceStatusChangedMtBuckets[i].threadId ==
          myThreadId and
          gDeviceStatusChangedMtBuckets[i].threadGen ==
          myThreadGen:
        gDeviceStatusChangedMtBuckets[i].hasListeners = true
        bucketExists = true
        break
    if not bucketExists:
      if gDeviceStatusChangedMtBucketCount >= gDeviceStatusChangedMtBucketCap:
        growDeviceStatusChangedMtBuckets()
      let chan = cast[ptr AsyncChannel[DeviceStatusChangedMtEventMsg]](createShared(
          AsyncChannel[DeviceStatusChangedMtEventMsg], 1))
      discard chan[].open()
      let idx = gDeviceStatusChangedMtBucketCount
      gDeviceStatusChangedMtBuckets[idx] = DeviceStatusChangedMtEventBucket(
          brokerCtx: brokerCtx, eventChan: chan,
          threadId: myThreadId, threadGen: myThreadGen,
          active: true, hasListeners: true)
      gDeviceStatusChangedMtBucketCount += 1
      spawnChan = chan
  if not bucketExists and not spawnChan.isNil:
    asyncSpawn processLoopDeviceStatusChanged(spawnChan,
        brokerCtx)
  return ok(DeviceStatusChangedListener(id: newId,
                                        threadId: myThreadId))

proc listen*(_: typedesc[DeviceStatusChanged];
             handler: DeviceStatusChangedListenerProc): Result[
    DeviceStatusChangedListener, string] =
  return listenDeviceStatusChangedMtImpl(DefaultBrokerContext,
      handler)

proc listen*(_: typedesc[DeviceStatusChanged];
             brokerCtx: BrokerContext;
             handler: DeviceStatusChangedListenerProc): Result[
    DeviceStatusChangedListener, string] =
  return listenDeviceStatusChangedMtImpl(brokerCtx,
      handler)

proc emitDeviceStatusChangedMtImpl(brokerCtx: BrokerContext;
                                   event: DeviceStatusChanged) {.
    async: (raises: []).} =
  ensureInitDeviceStatusChangedMtBroker()
  when compiles(event.isNil()):
    if event.isNil():
      error "Cannot emit uninitialized event object",
            eventType = "DeviceStatusChanged"
      return
  type
    EvTarget = object
      eventChan: ptr AsyncChannel[DeviceStatusChangedMtEventMsg]
      isSameThread: bool
  var targets: seq[EvTarget] = @[]
  let myThreadId = currentMtThreadId()
  withLock(gDeviceStatusChangedMtLock):
    for i in 0 ..< gDeviceStatusChangedMtBucketCount:
      if gDeviceStatusChangedMtBuckets[i].brokerCtx ==
          brokerCtx and
          gDeviceStatusChangedMtBuckets[i].active and
          gDeviceStatusChangedMtBuckets[i].hasListeners:
        targets.add(EvTarget(eventChan: gDeviceStatusChangedMtBuckets[
            i].eventChan, isSameThread: gDeviceStatusChangedMtBuckets[
            i].threadId ==
            myThreadId))
  if targets.len == 0:
    return
  for target in targets:
    if target.isSameThread:
      var idx = -1
      for i in 0 ..< gDeviceStatusChangedTvListenerCtxs.len:
        if gDeviceStatusChangedTvListenerCtxs[i] ==
            brokerCtx:
          idx = i
          break
      if idx >= 0:
        var callbacks: seq[DeviceStatusChangedListenerProc] = @[]
        for cb in gDeviceStatusChangedTvListenerHandlers[
            idx].values:
          callbacks.add(cb)
        for cb in callbacks:
          asyncSpawn notifyDeviceStatusChangedListener(cb,
              event)
    else:
      let msg = DeviceStatusChangedMtEventMsg(
          kind: DeviceStatusChangedMtEventMsgKind.emkEvent,
          event: event)
      target.eventChan[].sendSync(msg)

proc emit*(event: DeviceStatusChanged) {.async: (raises: []).} =
  await emitDeviceStatusChangedMtImpl(DefaultBrokerContext, event)

proc emit*(_: typedesc[DeviceStatusChanged];
           event: DeviceStatusChanged) {.async: (raises: []).} =
  await emitDeviceStatusChangedMtImpl(DefaultBrokerContext, event)

proc emit*(_: typedesc[DeviceStatusChanged];
           brokerCtx: BrokerContext;
           event: DeviceStatusChanged) {.async: (raises: []).} =
  await emitDeviceStatusChangedMtImpl(brokerCtx, event)

proc emit*(_: typedesc[DeviceStatusChanged]; deviceId: int64; name: string;
           online: bool; timestampMs: int64) {.async: (raises: []).} =
  await emitDeviceStatusChangedMtImpl(DefaultBrokerContext, DeviceStatusChanged(
      deviceId: deviceId, name: name, online: online, timestampMs: timestampMs))

proc emit*(_: typedesc[DeviceStatusChanged]; brokerCtx: BrokerContext;
           deviceId: int64; name: string; online: bool; timestampMs: int64) {.
    async: (raises: []).} =
  await emitDeviceStatusChangedMtImpl(brokerCtx, DeviceStatusChanged(
      deviceId: deviceId, name: name, online: online, timestampMs: timestampMs))

proc dropDeviceStatusChangedMtListenerImpl(brokerCtx: BrokerContext;
    handle: DeviceStatusChangedListener) =
  if handle.id == 0'u64:
    return
  if handle.threadId != currentMtThreadId():
    error "dropListener called from wrong thread",
          eventType = "DeviceStatusChanged",
          handleThread = repr(handle.threadId),
          currentThread = repr(currentMtThreadId())
    return
  var tvIdx = -1
  for i in 0 ..< gDeviceStatusChangedTvListenerCtxs.len:
    if gDeviceStatusChangedTvListenerCtxs[i] ==
        brokerCtx:
      tvIdx = i
      break
  if tvIdx < 0:
    return
  gDeviceStatusChangedTvListenerHandlers[tvIdx].del(
      handle.id)
  if gDeviceStatusChangedTvListenerHandlers[tvIdx].len == 0:
    gDeviceStatusChangedTvListenerCtxs.del(tvIdx)
    gDeviceStatusChangedTvListenerHandlers.del(tvIdx)
    gDeviceStatusChangedTvNextIds.del(tvIdx)
    let myThreadId = currentMtThreadId()
    let myThreadGen = currentMtThreadGen()
    withLock(gDeviceStatusChangedMtLock):
      for i in 0 ..< gDeviceStatusChangedMtBucketCount:
        if gDeviceStatusChangedMtBuckets[i].brokerCtx ==
            brokerCtx and
            gDeviceStatusChangedMtBuckets[i].threadId ==
            myThreadId and
            gDeviceStatusChangedMtBuckets[i].threadGen ==
            myThreadGen:
          gDeviceStatusChangedMtBuckets[i].hasListeners = false
          break

proc dropAllDeviceStatusChangedMtListenersImpl(
    brokerCtx: BrokerContext) =
  ensureInitDeviceStatusChangedMtBroker()
  let myThreadId = currentMtThreadId()
  var chansToClear: seq[ptr AsyncChannel[
      DeviceStatusChangedMtEventMsg]] = @[]
  withLock(gDeviceStatusChangedMtLock):
    for i in 0 ..< gDeviceStatusChangedMtBucketCount:
      if gDeviceStatusChangedMtBuckets[i].brokerCtx ==
          brokerCtx and
          gDeviceStatusChangedMtBuckets[i].hasListeners:
        gDeviceStatusChangedMtBuckets[i].hasListeners = false
        if gDeviceStatusChangedMtBuckets[i].threadId !=
            myThreadId:
          chansToClear.add(gDeviceStatusChangedMtBuckets[i].eventChan)
  var tvIdx = -1
  for i in 0 ..< gDeviceStatusChangedTvListenerCtxs.len:
    if gDeviceStatusChangedTvListenerCtxs[i] ==
        brokerCtx:
      tvIdx = i
      break
  if tvIdx >= 0:
    gDeviceStatusChangedTvListenerHandlers[tvIdx].clear()
    gDeviceStatusChangedTvListenerCtxs.del(tvIdx)
    gDeviceStatusChangedTvListenerHandlers.del(tvIdx)
    gDeviceStatusChangedTvNextIds.del(tvIdx)
  for chan in chansToClear:
    chan[].sendSync(DeviceStatusChangedMtEventMsg(
        kind: DeviceStatusChangedMtEventMsgKind.emkClearListeners))

proc dropListener*(_: typedesc[DeviceStatusChanged];
                   handle: DeviceStatusChangedListener) =
  dropDeviceStatusChangedMtListenerImpl(DefaultBrokerContext, handle)

proc dropListener*(_: typedesc[DeviceStatusChanged];
                   brokerCtx: BrokerContext;
                   handle: DeviceStatusChangedListener) =
  dropDeviceStatusChangedMtListenerImpl(brokerCtx, handle)

proc dropAllListeners*(_: typedesc[DeviceStatusChanged]) =
  dropAllDeviceStatusChangedMtListenersImpl(DefaultBrokerContext)

proc dropAllListeners*(_: typedesc[DeviceStatusChanged];
                       brokerCtx: BrokerContext) =
  dropAllDeviceStatusChangedMtListenersImpl(brokerCtx)

const
  DeviceStatusChangedApiTypeId* = 0
type
  DeviceStatusChangedCCallback* = proc (deviceId: int64; name: cstring;
                                        online: bool; timestampMs: int64) {.
      cdecl.}
type
  RegisterEventListenerResult* = object
    handle*: uint64
    success*: bool
  RegisterEventListenerResultProviderWithArgs = proc (action: int32;
      eventTypeId: int32; callbackPtr: pointer; listenerHandle: uint64): Future[
      Result[RegisterEventListenerResult, string]] {.async.}
  RegisterEventListenerResultMtRequestMsg = object
    isShutdown: bool
    requestKind: int
    action: int32
    eventTypeId: int32
    callbackPtr: pointer
    listenerHandle: uint64
    responseChan: ptr AsyncChannel[Result[RegisterEventListenerResult, string]]
  RegisterEventListenerResultMtBucket = object
    brokerCtx: BrokerContext
    requestChan: ptr AsyncChannel[RegisterEventListenerResultMtRequestMsg]
    threadId: pointer
    threadGen: uint64
var gRegisterEventListenerResultMtBuckets: ptr UncheckedArray[
    RegisterEventListenerResultMtBucket]
var gRegisterEventListenerResultMtBucketCount: int
var gRegisterEventListenerResultMtBucketCap: int
var gRegisterEventListenerResultMtLock: Lock
var gRegisterEventListenerResultMtInit: Atomic[int] ## 0 = uninitialised, 1 = initialising, 2 = ready.
                                                    ## CAS(0→1) wins the race; losers spin until 2.
proc ensureInitRegisterEventListenerResultMtBroker() =
  if gRegisterEventListenerResultMtInit.load(moRelaxed) == 2:
    return
  var expected = 0
  if gRegisterEventListenerResultMtInit.compareExchange(expected, 1,
      moAcquire, moRelaxed):
    initLock(gRegisterEventListenerResultMtLock)
    gRegisterEventListenerResultMtBucketCap = 4
    gRegisterEventListenerResultMtBuckets = cast[ptr UncheckedArray[
        RegisterEventListenerResultMtBucket]](createShared(
        RegisterEventListenerResultMtBucket,
        gRegisterEventListenerResultMtBucketCap))
    gRegisterEventListenerResultMtBucketCount = 0
    gRegisterEventListenerResultMtInit.store(2, moRelease)
  else:
    while gRegisterEventListenerResultMtInit.load(moAcquire) != 2:
      discard

proc growRegisterEventListenerResultMtBuckets() =
  ## Must be called under lock.
  let newCap = gRegisterEventListenerResultMtBucketCap * 2
  let newBuf = cast[ptr UncheckedArray[
      RegisterEventListenerResultMtBucket]](createShared(
      RegisterEventListenerResultMtBucket, newCap))
  for i in 0 ..< gRegisterEventListenerResultMtBucketCount:
    newBuf[i] = gRegisterEventListenerResultMtBuckets[
        i]
  deallocShared(gRegisterEventListenerResultMtBuckets)
  gRegisterEventListenerResultMtBuckets = newBuf
  gRegisterEventListenerResultMtBucketCap = newCap

var gRegisterEventListenerResultMtRequestTimeout*: Duration = seconds(5) ## Default timeout for cross-thread requests. Same-thread requests
                                                                         ## bypass this (they call the provider directly).
                                                                         ## NOTE: Set during initialization before spawning worker threads.
                                                                         ## Reading from multiple threads is safe on x86-64 (aligned int64),
                                                                         ## but concurrent writes are not guaranteed atomic on all platforms.
proc setRequestTimeout*(_: typedesc[RegisterEventListenerResult];
                        timeout: Duration) =
  ## Set the cross-thread request timeout for this broker type.
  ## Call this during initialization before spawning worker threads.
  gRegisterEventListenerResultMtRequestTimeout = timeout

proc requestTimeout*(_: typedesc[RegisterEventListenerResult]): Duration =
  ## Get the current cross-thread request timeout for this broker type.
  gRegisterEventListenerResultMtRequestTimeout

var gRegisterEventListenerResultTvWithArgCtxs {.threadvar.}: seq[BrokerContext]
var gRegisterEventListenerResultTvWithArgHandlers {.threadvar.}: seq[
    RegisterEventListenerResultProviderWithArgs]
proc processLoopRegisterEventListenerResult(
    requestChan: ptr AsyncChannel[RegisterEventListenerResultMtRequestMsg];
    loopCtx: BrokerContext) {.async: (raises: []).} =
  while true:
    let recvRes = catch do:
      await requestChan.recv()
    if recvRes.isErr():
      break
    let msg = recvRes.get()
    if msg.isShutdown:
      break
    if msg.requestKind == 1:
      var handler1: RegisterEventListenerResultProviderWithArgs
      for i in 0 ..< gRegisterEventListenerResultTvWithArgCtxs.len:
        if gRegisterEventListenerResultTvWithArgCtxs[i] ==
            loopCtx:
          handler1 = gRegisterEventListenerResultTvWithArgHandlers[i]
          break
      if handler1.isNil():
        msg.responseChan[].sendSync(err(Result[RegisterEventListenerResult,
            string], "RequestBroker(" & "RegisterEventListenerResult" &
            "): no provider registered for input signature"))
      else:
        let catchedRes = catch do:
          await handler1(msg.action, msg.eventTypeId, msg.callbackPtr,
                         msg.listenerHandle)
        if catchedRes.isErr():
          msg.responseChan[].sendSync(err(
              Result[RegisterEventListenerResult, string], "RequestBroker(" &
              "RegisterEventListenerResult" &
              "): provider threw exception: " &
              catchedRes.error.msg))
        else:
          let providerRes = catchedRes.get()
          if providerRes.isOk():
            let resultValue = providerRes.get()
            when compiles(resultValue.isNil()):
              if resultValue.isNil():
                msg.responseChan[].sendSync(err(
                    Result[RegisterEventListenerResult, string], "RequestBroker(" &
                    "RegisterEventListenerResult" &
                    "): provider returned nil result"))
                continue
          msg.responseChan[].sendSync(providerRes)

proc setProvider*(_: typedesc[RegisterEventListenerResult]; handler: RegisterEventListenerResultProviderWithArgs): Result[
    void, string] =
  ensureInitRegisterEventListenerResultMtBroker()
  let myThreadGen = currentMtThreadGen()
  for i in 0 ..< gRegisterEventListenerResultTvWithArgCtxs.len:
    if gRegisterEventListenerResultTvWithArgCtxs[i] ==
        DefaultBrokerContext:
      var isStale = true
      withLock(gRegisterEventListenerResultMtLock):
        for j in 0 ..< gRegisterEventListenerResultMtBucketCount:
          if gRegisterEventListenerResultMtBuckets[j].brokerCtx ==
              DefaultBrokerContext and
              gRegisterEventListenerResultMtBuckets[j].threadId ==
              currentMtThreadId() and
              gRegisterEventListenerResultMtBuckets[j].threadGen ==
              myThreadGen:
            isStale = false
            break
      if isStale:
        gRegisterEventListenerResultTvWithArgCtxs.del(i)
        gRegisterEventListenerResultTvWithArgHandlers.del(i)
        break
      else:
        return err("Provider already set")
  gRegisterEventListenerResultTvWithArgCtxs.add(DefaultBrokerContext)
  gRegisterEventListenerResultTvWithArgHandlers.add(handler)
  var spawnChan: ptr AsyncChannel[
      RegisterEventListenerResultMtRequestMsg]
  withLock(gRegisterEventListenerResultMtLock):
    for i in 0 ..< gRegisterEventListenerResultMtBucketCount:
      if gRegisterEventListenerResultMtBuckets[i].brokerCtx ==
          DefaultBrokerContext:
        if gRegisterEventListenerResultMtBuckets[i].threadId ==
            currentMtThreadId() and
            gRegisterEventListenerResultMtBuckets[i].threadGen ==
            myThreadGen:
          return ok()
        else:
          gRegisterEventListenerResultTvWithArgCtxs.setLen(
              gRegisterEventListenerResultTvWithArgCtxs.len - 1)
          gRegisterEventListenerResultTvWithArgHandlers.setLen(
              gRegisterEventListenerResultTvWithArgHandlers.len - 1)
          return err("RequestBroker(" & "RegisterEventListenerResult" &
              "): provider already set from another thread")
    if gRegisterEventListenerResultMtBucketCount >=
        gRegisterEventListenerResultMtBucketCap:
      growRegisterEventListenerResultMtBuckets()
    spawnChan = cast[ptr AsyncChannel[
        RegisterEventListenerResultMtRequestMsg]](createShared(
        AsyncChannel[RegisterEventListenerResultMtRequestMsg], 1))
    discard spawnChan[].open()
    let idx = gRegisterEventListenerResultMtBucketCount
    gRegisterEventListenerResultMtBuckets[idx] = RegisterEventListenerResultMtBucket(
        brokerCtx: DefaultBrokerContext, requestChan: spawnChan,
        threadId: currentMtThreadId(), threadGen: myThreadGen)
    gRegisterEventListenerResultMtBucketCount += 1
  if not spawnChan.isNil:
    asyncSpawn processLoopRegisterEventListenerResult(spawnChan,
        DefaultBrokerContext)
  return ok()

proc setProvider*(_: typedesc[RegisterEventListenerResult];
                  brokerCtx: BrokerContext; handler: RegisterEventListenerResultProviderWithArgs): Result[
    void, string] =
  if brokerCtx == DefaultBrokerContext:
    return setProvider(RegisterEventListenerResult, handler)
  ensureInitRegisterEventListenerResultMtBroker()
  let myThreadGen = currentMtThreadGen()
  for i in 0 ..< gRegisterEventListenerResultTvWithArgCtxs.len:
    if gRegisterEventListenerResultTvWithArgCtxs[i] ==
        brokerCtx:
      var isStale = true
      withLock(gRegisterEventListenerResultMtLock):
        for j in 0 ..< gRegisterEventListenerResultMtBucketCount:
          if gRegisterEventListenerResultMtBuckets[j].brokerCtx ==
              brokerCtx and
              gRegisterEventListenerResultMtBuckets[j].threadId ==
              currentMtThreadId() and
              gRegisterEventListenerResultMtBuckets[j].threadGen ==
              myThreadGen:
            isStale = false
            break
      if isStale:
        gRegisterEventListenerResultTvWithArgCtxs.del(i)
        gRegisterEventListenerResultTvWithArgHandlers.del(i)
        break
      else:
        return err("RequestBroker(" & "RegisterEventListenerResult" &
            "): provider already set for broker context " &
            $brokerCtx)
  gRegisterEventListenerResultTvWithArgCtxs.add(brokerCtx)
  gRegisterEventListenerResultTvWithArgHandlers.add(handler)
  var spawnChan: ptr AsyncChannel[
      RegisterEventListenerResultMtRequestMsg]
  withLock(gRegisterEventListenerResultMtLock):
    for i in 0 ..< gRegisterEventListenerResultMtBucketCount:
      if gRegisterEventListenerResultMtBuckets[i].brokerCtx ==
          brokerCtx:
        if gRegisterEventListenerResultMtBuckets[i].threadId ==
            currentMtThreadId() and
            gRegisterEventListenerResultMtBuckets[i].threadGen ==
            myThreadGen:
          return ok()
        else:
          gRegisterEventListenerResultTvWithArgCtxs.setLen(
              gRegisterEventListenerResultTvWithArgCtxs.len - 1)
          gRegisterEventListenerResultTvWithArgHandlers.setLen(
              gRegisterEventListenerResultTvWithArgHandlers.len - 1)
          return err("RequestBroker(" & "RegisterEventListenerResult" &
              "): provider already set from another thread for context " &
              $brokerCtx)
    if gRegisterEventListenerResultMtBucketCount >=
        gRegisterEventListenerResultMtBucketCap:
      growRegisterEventListenerResultMtBuckets()
    spawnChan = cast[ptr AsyncChannel[
        RegisterEventListenerResultMtRequestMsg]](createShared(
        AsyncChannel[RegisterEventListenerResultMtRequestMsg], 1))
    discard spawnChan[].open()
    let idx = gRegisterEventListenerResultMtBucketCount
    gRegisterEventListenerResultMtBuckets[idx] = RegisterEventListenerResultMtBucket(
        brokerCtx: brokerCtx, requestChan: spawnChan,
        threadId: currentMtThreadId(), threadGen: myThreadGen)
    gRegisterEventListenerResultMtBucketCount += 1
  if not spawnChan.isNil:
    asyncSpawn processLoopRegisterEventListenerResult(spawnChan,
        brokerCtx)
  return ok()

proc request*(_: typedesc[RegisterEventListenerResult]): Future[
    Result[RegisterEventListenerResult, string]] {.async: (raises: []).} =
  return err("RequestBroker(" & "RegisterEventListenerResult" &
      "): no zero-arg provider registered")

proc request*(_: typedesc[RegisterEventListenerResult]; action: int32;
              eventTypeId: int32; callbackPtr: pointer; listenerHandle: uint64): Future[
    Result[RegisterEventListenerResult, string]] {.async: (raises: []).} =
  return await request(RegisterEventListenerResult, DefaultBrokerContext,
                       action, eventTypeId, callbackPtr, listenerHandle)

proc request*(_: typedesc[RegisterEventListenerResult];
              brokerCtx: BrokerContext; action: int32; eventTypeId: int32;
              callbackPtr: pointer; listenerHandle: uint64): Future[
    Result[RegisterEventListenerResult, string]] {.async: (raises: []).} =
  ensureInitRegisterEventListenerResultMtBroker()
  var reqChan: ptr AsyncChannel[RegisterEventListenerResultMtRequestMsg]
  var sameThread = false
  let myThreadGen = currentMtThreadGen()
  withLock(gRegisterEventListenerResultMtLock):
    for i in 0 ..< gRegisterEventListenerResultMtBucketCount:
      if gRegisterEventListenerResultMtBuckets[i].brokerCtx ==
          brokerCtx:
        if gRegisterEventListenerResultMtBuckets[i].threadId ==
            currentMtThreadId() and
            gRegisterEventListenerResultMtBuckets[i].threadGen ==
            myThreadGen:
          sameThread = true
        else:
          reqChan = gRegisterEventListenerResultMtBuckets[i].requestChan
        break
  if sameThread:
    var provider: RegisterEventListenerResultProviderWithArgs
    for i in 0 ..< gRegisterEventListenerResultTvWithArgCtxs.len:
      if gRegisterEventListenerResultTvWithArgCtxs[i] ==
          brokerCtx:
        provider = gRegisterEventListenerResultTvWithArgHandlers[
            i]
        break
    if provider.isNil():
      return err("RequestBroker(" & "RegisterEventListenerResult" &
          "): no provider registered for input signature")
    let catchedRes = catch do:
      await provider(action, eventTypeId, callbackPtr, listenerHandle)
    if catchedRes.isErr():
      return err("RequestBroker(" & "RegisterEventListenerResult" &
          "): provider threw exception: " &
          catchedRes.error.msg)
    let providerRes = catchedRes.get()
    if providerRes.isOk():
      let resultValue = providerRes.get()
      when compiles(resultValue.isNil()):
        if resultValue.isNil():
          return err("RequestBroker(" & "RegisterEventListenerResult" &
              "): provider returned nil result")
    return providerRes
  else:
    if reqChan.isNil():
      return err("RequestBroker(" & "RegisterEventListenerResult" &
          "): no provider registered for broker context " &
          $brokerCtx)
    let respChan = cast[ptr AsyncChannel[
        Result[RegisterEventListenerResult, string]]](createShared(
        AsyncChannel[Result[RegisterEventListenerResult, string]], 1))
    discard respChan[].open()
    var msg = RegisterEventListenerResultMtRequestMsg(
        isShutdown: false, requestKind: 1, action: action,
        eventTypeId: eventTypeId, callbackPtr: callbackPtr,
        listenerHandle: listenerHandle, responseChan: respChan)
    reqChan[].sendSync(msg)
    let recvFut = respChan.recv()
    let completedRes = catch do:
      await withTimeout(recvFut,
                        gRegisterEventListenerResultMtRequestTimeout)
    if completedRes.isErr():
      return err("RequestBroker(" & "RegisterEventListenerResult" &
          "): recv failed: " &
          completedRes.error.msg)
    if not completedRes.get():
      return err("RequestBroker(" & "RegisterEventListenerResult" &
          "): cross-thread request timed out after " &
          $gRegisterEventListenerResultMtRequestTimeout)
    respChan[].close()
    deallocShared(respChan)
    let recvRes = catch do:
      recvFut.read()
    if recvRes.isErr():
      return err("RequestBroker(" & "RegisterEventListenerResult" &
          "): recv failed: " &
          recvRes.error.msg)
    return recvRes.get()

proc clearProvider*(_: typedesc[RegisterEventListenerResult];
                    brokerCtx: BrokerContext) =
  ensureInitRegisterEventListenerResultMtBroker()
  var reqChan: ptr AsyncChannel[
      RegisterEventListenerResultMtRequestMsg]
  var isProviderThread = false
  let myThreadGen = currentMtThreadGen()
  withLock(gRegisterEventListenerResultMtLock):
    var foundIdx = -1
    for i in 0 ..< gRegisterEventListenerResultMtBucketCount:
      if gRegisterEventListenerResultMtBuckets[i].brokerCtx ==
          brokerCtx:
        reqChan = gRegisterEventListenerResultMtBuckets[i].requestChan
        isProviderThread = (gRegisterEventListenerResultMtBuckets[
            i].threadId ==
            currentMtThreadId() and
            gRegisterEventListenerResultMtBuckets[i].threadGen ==
            myThreadGen)
        foundIdx = i
        break
    if foundIdx >= 0:
      for i in foundIdx ..<
          gRegisterEventListenerResultMtBucketCount - 1:
        gRegisterEventListenerResultMtBuckets[i] = gRegisterEventListenerResultMtBuckets[
            i + 1]
      gRegisterEventListenerResultMtBucketCount -= 1
  if isProviderThread:
    for i in countdown(gRegisterEventListenerResultTvWithArgCtxs.len -
        1, 0):
      if gRegisterEventListenerResultTvWithArgCtxs[i] ==
          brokerCtx:
        gRegisterEventListenerResultTvWithArgCtxs.del(i)
        gRegisterEventListenerResultTvWithArgHandlers.del(i)
        break
  elif not reqChan.isNil():
    trace "clearProvider called from non-provider thread; " &
        "threadvar entries on provider thread are stale but harmless " &
        "(next setProvider will detect and clean them)",
          brokerType = "RegisterEventListenerResult"
  if not reqChan.isNil():
    var shutdownMsg = RegisterEventListenerResultMtRequestMsg(
        isShutdown: true)
    reqChan[].sendSync(shutdownMsg)

proc clearProvider*(_: typedesc[RegisterEventListenerResult]) =
  clearProvider(RegisterEventListenerResult, DefaultBrokerContext)

var gDeviceStatusChangedApiListenerHandles {.threadvar.}: seq[
    DeviceStatusChangedListener]
proc registerDeviceStatusChangedCallback(ctx: BrokerContext;
    callbackPtr: pointer): Result[RegisterEventListenerResult, string] =
  let cb_587228063 = cast[DeviceStatusChangedCCallback](callbackPtr)
  let wrapper: DeviceStatusChangedListenerProc = proc (
      evt_587228062: DeviceStatusChanged): Future[void] {.async: (raises: []).} =
    when defined(brokerDebug):
      debugEcho "[API-EVENT] Entering wrapper, cb isNil=", cb_587228063.isNil()
    let c_name_587228064 = allocSharedCString(evt_587228062.name)
    when defined(brokerDebug):
      debugEcho "[API-EVENT] post-alloc, calling cb"
    {.gcsafe.}:
      try:
        cb_587228063(evt_587228062.deviceId, c_name_587228064, evt_587228062.online,
                     evt_587228062.timestampMs)
      except Exception:
        when defined(brokerDebug):
          debugEcho "[API-EVENT] Callback exception: ", getCurrentExceptionMsg()
        discard
    when defined(brokerDebug):
      debugEcho "[API-EVENT] cb done, freeing"
    freeSharedCString(c_name_587228064)
  let listenRes = DeviceStatusChanged.listen(ctx,
      wrapper)
  if listenRes.isOk():
    gDeviceStatusChangedApiListenerHandles.add(listenRes.get())
    return ok(RegisterEventListenerResult(handle: listenRes.get().id,
        success: true))
  else:
    return err(listenRes.error())

proc unregisterDeviceStatusChangedCallback(ctx: BrokerContext;
    targetId: uint64): Result[RegisterEventListenerResult, string] =
  for i in 0 ..< gDeviceStatusChangedApiListenerHandles.len:
    if gDeviceStatusChangedApiListenerHandles[i].id ==
        targetId:
      DeviceStatusChanged.dropListener(ctx, gDeviceStatusChangedApiListenerHandles[
          i])
      gDeviceStatusChangedApiListenerHandles.del(i)
      return ok(RegisterEventListenerResult(handle: targetId,
          success: true))
  return err("Handle not found")

proc unregisterAllDeviceStatusChangedCallbacks(ctx: BrokerContext): Result[
    RegisterEventListenerResult, string] =
  for h in gDeviceStatusChangedApiListenerHandles:
    DeviceStatusChanged.dropListener(ctx, h)
  gDeviceStatusChangedApiListenerHandles.setLen(0)
  return ok(RegisterEventListenerResult(handle: 0'u64, success: true))

proc handleDeviceStatusChangedRegistration(ctx: BrokerContext;
    action: int32; callbackPtr: pointer;
    listenerHandle: uint64): Future[
    Result[RegisterEventListenerResult, string]] {.async: (raises: []).} =
  case action
  of 0:
    return registerDeviceStatusChangedCallback(ctx,
        callbackPtr)
  of 1:
    return unregisterDeviceStatusChangedCallback(ctx,
        listenerHandle)
  of 2:
    return unregisterAllDeviceStatusChangedCallbacks(ctx)
  else:
    return err("Unknown action: " & $action)

proc cleanupDeviceStatusChangedListeners(ctx: BrokerContext) =
  DeviceStatusChanged.dropAllListeners(ctx)

proc onDeviceStatusChanged(ctx: uint32;
                           callback: DeviceStatusChangedCCallback): uint64 {.
    exportc: "onDeviceStatusChanged", cdecl, dynlib.} =
  let res = waitFor RegisterEventListenerResult.request(
      BrokerContext(ctx), 0'i32, int32(DeviceStatusChangedApiTypeId),
      cast[pointer](callback), 0'u64)
  if res.isOk():
    res.get().handle
  else:
    0'u64

proc offDeviceStatusChanged(ctx: uint32; handle: uint64) {.
    exportc: "offDeviceStatusChanged", cdecl, dynlib.} =
  if handle == 0'u64:
    discard waitFor RegisterEventListenerResult.request(
        BrokerContext(ctx), 2'i32,
        int32(DeviceStatusChangedApiTypeId), nil, 0'u64)
  else:
    discard waitFor RegisterEventListenerResult.request(
        BrokerContext(ctx), 1'i32,
        int32(DeviceStatusChangedApiTypeId), nil, handle)
# ===== EventBroker(API): DeviceDiscovered =====
## Flow:
## - Same event-registration pipeline as DeviceStatusChanged, with per-event callback signatures and cleanup helpers.
## Collapsed identical repeated expansion block.
## The removed copy was byte-for-byte identical to the first generated MT/runtime block.

type
  DeviceDiscovered* = object
    deviceId*: int64
    name*: string
    deviceType*: string
    address*: string
  DeviceDiscoveredListener* = object
    id*: uint64
    threadId*: pointer       ## Thread that registered this listener (for validation on drop).
  DeviceDiscoveredListenerProc* = proc (event: DeviceDiscovered): Future[
      void] {.async: (raises: []), gcsafe.}
  DeviceDiscoveredMtEventMsgKind {.pure.} = enum
    emkEvent,               ## Normal event delivery
    emkClearListeners,      ## Clear threadvar handlers, keep processLoop alive
    emkShutdown              ## Drain in-flight tasks and exit processLoop
  DeviceDiscoveredMtEventMsg = object
    kind: DeviceDiscoveredMtEventMsgKind
    event: DeviceDiscovered
  DeviceDiscoveredMtEventBucket = object
    brokerCtx: BrokerContext
    eventChan: ptr AsyncChannel[DeviceDiscoveredMtEventMsg]
    threadId: pointer
    threadGen: uint64        ## Disambiguates reused threadvar addresses
    active: bool
    hasListeners: bool
var gDeviceDiscoveredMtBuckets: ptr UncheckedArray[DeviceDiscoveredMtEventBucket]
var gDeviceDiscoveredMtBucketCount: int
var gDeviceDiscoveredMtBucketCap: int
var gDeviceDiscoveredMtLock: Lock
var gDeviceDiscoveredMtInit: Atomic[int] ## 0 = uninitialised, 1 = initialising, 2 = ready.
                                         ## CAS(0→1) wins the race; losers spin until 2.
proc ensureInitDeviceDiscoveredMtBroker() =
  if gDeviceDiscoveredMtInit.load(moRelaxed) == 2:
    return
  var expected = 0
  if gDeviceDiscoveredMtInit.compareExchange(expected, 1, moAcquire,
      moRelaxed):
    initLock(gDeviceDiscoveredMtLock)
    gDeviceDiscoveredMtBucketCap = 4
    gDeviceDiscoveredMtBuckets = cast[ptr UncheckedArray[
        DeviceDiscoveredMtEventBucket]](createShared(
        DeviceDiscoveredMtEventBucket, gDeviceDiscoveredMtBucketCap))
    gDeviceDiscoveredMtBucketCount = 0
    gDeviceDiscoveredMtInit.store(2, moRelease)
  else:
    while gDeviceDiscoveredMtInit.load(moAcquire) != 2:
      discard

proc growDeviceDiscoveredMtBuckets() =
  ## Must be called under lock.
  let newCap = gDeviceDiscoveredMtBucketCap * 2
  let newBuf = cast[ptr UncheckedArray[DeviceDiscoveredMtEventBucket]](createShared(
      DeviceDiscoveredMtEventBucket, newCap))
  for i in 0 ..< gDeviceDiscoveredMtBucketCount:
    newBuf[i] = gDeviceDiscoveredMtBuckets[i]
  deallocShared(gDeviceDiscoveredMtBuckets)
  gDeviceDiscoveredMtBuckets = newBuf
  gDeviceDiscoveredMtBucketCap = newCap

var gDeviceDiscoveredTvListenerCtxs {.threadvar.}: seq[BrokerContext]
var gDeviceDiscoveredTvListenerHandlers {.threadvar.}: seq[
    Table[uint64, DeviceDiscoveredListenerProc]]
var gDeviceDiscoveredTvNextIds {.threadvar.}: seq[uint64]
proc notifyDeviceDiscoveredListener(callback: DeviceDiscoveredListenerProc;
                                    event: DeviceDiscovered): Future[
    void] {.async: (raises: []).} =
  if callback.isNil():
    return
  try:
    await callback(event)
  except CatchableError:
    error "Failed to execute event listener", eventType = "DeviceDiscovered",
          error = getCurrentExceptionMsg()

proc processLoopDeviceDiscovered(eventChan: ptr AsyncChannel[
    DeviceDiscoveredMtEventMsg]; loopCtx: BrokerContext) {.async: (raises: []).} =
  var inFlight: seq[Future[void]] = @[]
  proc drainInFlight() {.async: (raises: []).} =
    for fut in inFlight:
      if not fut.finished():
        try:
          discard await withTimeout(fut, seconds(5))
        except CatchableError:
          discard
    inFlight.setLen(0)

  proc clearThreadvarListeners() =
    for i in 0 ..< gDeviceDiscoveredTvListenerCtxs.len:
      if gDeviceDiscoveredTvListenerCtxs[i] == loopCtx:
        gDeviceDiscoveredTvListenerHandlers[i].clear()
        gDeviceDiscoveredTvListenerCtxs.del(i)
        gDeviceDiscoveredTvListenerHandlers.del(i)
        gDeviceDiscoveredTvNextIds.del(i)
        break

  while true:
    let recvRes = catch do:
      await eventChan.recv()
    if recvRes.isErr():
      break
    let msg = recvRes.get()
    case msg.kind
    of DeviceDiscoveredMtEventMsgKind.emkShutdown:
      await drainInFlight()
      clearThreadvarListeners()
      break
    of DeviceDiscoveredMtEventMsgKind.emkClearListeners:
      await drainInFlight()
      clearThreadvarListeners()
    of DeviceDiscoveredMtEventMsgKind.emkEvent:
      var j = 0
      while j < inFlight.len:
        if inFlight[j].finished():
          try:
            await inFlight[j]
          except CatchableError:
            discard
          inFlight.del(j)
        else:
          inc j
      var idx = -1
      for i in 0 ..< gDeviceDiscoveredTvListenerCtxs.len:
        if gDeviceDiscoveredTvListenerCtxs[i] == loopCtx:
          idx = i
          break
      if idx >= 0:
        var callbacks: seq[DeviceDiscoveredListenerProc] = @[]
        for cb in gDeviceDiscoveredTvListenerHandlers[idx].values:
          callbacks.add(cb)
        for cb in callbacks:
          let fut = notifyDeviceDiscoveredListener(cb,
              msg.event)
          inFlight.add(fut)

proc listenDeviceDiscoveredMtImpl(brokerCtx: BrokerContext;
    handler: DeviceDiscoveredListenerProc): Result[
    DeviceDiscoveredListener, string] =
  if handler.isNil():
    return err("Must provide a non-nil event handler")
  ensureInitDeviceDiscoveredMtBroker()
  var tvIdx = -1
  for i in 0 ..< gDeviceDiscoveredTvListenerCtxs.len:
    if gDeviceDiscoveredTvListenerCtxs[i] == brokerCtx:
      tvIdx = i
      break
  if tvIdx < 0:
    gDeviceDiscoveredTvListenerCtxs.add(brokerCtx)
    gDeviceDiscoveredTvListenerHandlers.add(
        initTable[uint64, DeviceDiscoveredListenerProc]())
    gDeviceDiscoveredTvNextIds.add(1'u64)
    tvIdx = gDeviceDiscoveredTvListenerCtxs.len - 1
  if gDeviceDiscoveredTvNextIds[tvIdx] == high(uint64):
    return err("Cannot add more listeners: ID space exhausted")
  let newId = gDeviceDiscoveredTvNextIds[tvIdx]
  gDeviceDiscoveredTvNextIds[tvIdx] += 1
  gDeviceDiscoveredTvListenerHandlers[tvIdx][newId] = handler
  let myThreadId = currentMtThreadId()
  let myThreadGen = currentMtThreadGen()
  var bucketExists = false
  var spawnChan: ptr AsyncChannel[DeviceDiscoveredMtEventMsg]
  withLock(gDeviceDiscoveredMtLock):
    for i in 0 ..< gDeviceDiscoveredMtBucketCount:
      if gDeviceDiscoveredMtBuckets[i].brokerCtx ==
          brokerCtx and
          gDeviceDiscoveredMtBuckets[i].threadId ==
          myThreadId and
          gDeviceDiscoveredMtBuckets[i].threadGen ==
          myThreadGen:
        gDeviceDiscoveredMtBuckets[i].hasListeners = true
        bucketExists = true
        break
    if not bucketExists:
      if gDeviceDiscoveredMtBucketCount >= gDeviceDiscoveredMtBucketCap:
        growDeviceDiscoveredMtBuckets()
      let chan = cast[ptr AsyncChannel[DeviceDiscoveredMtEventMsg]](createShared(
          AsyncChannel[DeviceDiscoveredMtEventMsg], 1))
      discard chan[].open()
      let idx = gDeviceDiscoveredMtBucketCount
      gDeviceDiscoveredMtBuckets[idx] = DeviceDiscoveredMtEventBucket(
          brokerCtx: brokerCtx, eventChan: chan,
          threadId: myThreadId, threadGen: myThreadGen,
          active: true, hasListeners: true)
      gDeviceDiscoveredMtBucketCount += 1
      spawnChan = chan
  if not bucketExists and not spawnChan.isNil:
    asyncSpawn processLoopDeviceDiscovered(spawnChan,
        brokerCtx)
  return ok(DeviceDiscoveredListener(id: newId,
                                     threadId: myThreadId))

proc listen*(_: typedesc[DeviceDiscovered];
             handler: DeviceDiscoveredListenerProc): Result[
    DeviceDiscoveredListener, string] =
  return listenDeviceDiscoveredMtImpl(DefaultBrokerContext, handler)

proc listen*(_: typedesc[DeviceDiscovered]; brokerCtx: BrokerContext;
             handler: DeviceDiscoveredListenerProc): Result[
    DeviceDiscoveredListener, string] =
  return listenDeviceDiscoveredMtImpl(brokerCtx, handler)

proc emitDeviceDiscoveredMtImpl(brokerCtx: BrokerContext;
                                event: DeviceDiscovered) {.
    async: (raises: []).} =
  ensureInitDeviceDiscoveredMtBroker()
  when compiles(event.isNil()):
    if event.isNil():
      error "Cannot emit uninitialized event object",
            eventType = "DeviceDiscovered"
      return
  type
    EvTarget = object
      eventChan: ptr AsyncChannel[DeviceDiscoveredMtEventMsg]
      isSameThread: bool
  var targets: seq[EvTarget] = @[]
  let myThreadId = currentMtThreadId()
  withLock(gDeviceDiscoveredMtLock):
    for i in 0 ..< gDeviceDiscoveredMtBucketCount:
      if gDeviceDiscoveredMtBuckets[i].brokerCtx ==
          brokerCtx and
          gDeviceDiscoveredMtBuckets[i].active and
          gDeviceDiscoveredMtBuckets[i].hasListeners:
        targets.add(EvTarget(
            eventChan: gDeviceDiscoveredMtBuckets[i].eventChan, isSameThread: gDeviceDiscoveredMtBuckets[
            i].threadId ==
            myThreadId))
  if targets.len == 0:
    return
  for target in targets:
    if target.isSameThread:
      var idx = -1
      for i in 0 ..< gDeviceDiscoveredTvListenerCtxs.len:
        if gDeviceDiscoveredTvListenerCtxs[i] ==
            brokerCtx:
          idx = i
          break
      if idx >= 0:
        var callbacks: seq[DeviceDiscoveredListenerProc] = @[]
        for cb in gDeviceDiscoveredTvListenerHandlers[idx].values:
          callbacks.add(cb)
        for cb in callbacks:
          asyncSpawn notifyDeviceDiscoveredListener(cb,
              event)
    else:
      let msg = DeviceDiscoveredMtEventMsg(
          kind: DeviceDiscoveredMtEventMsgKind.emkEvent, event: event)
      target.eventChan[].sendSync(msg)

proc emit*(event: DeviceDiscovered) {.async: (raises: []).} =
  await emitDeviceDiscoveredMtImpl(DefaultBrokerContext, event)

proc emit*(_: typedesc[DeviceDiscovered]; event: DeviceDiscovered) {.
    async: (raises: []).} =
  await emitDeviceDiscoveredMtImpl(DefaultBrokerContext, event)

proc emit*(_: typedesc[DeviceDiscovered]; brokerCtx: BrokerContext;
           event: DeviceDiscovered) {.async: (raises: []).} =
  await emitDeviceDiscoveredMtImpl(brokerCtx, event)

proc emit*(_: typedesc[DeviceDiscovered]; deviceId: int64; name: string;
           deviceType: string; address: string) {.async: (raises: []).} =
  await emitDeviceDiscoveredMtImpl(DefaultBrokerContext, DeviceDiscovered(
      deviceId: deviceId, name: name, deviceType: deviceType, address: address))

proc emit*(_: typedesc[DeviceDiscovered]; brokerCtx: BrokerContext;
           deviceId: int64; name: string; deviceType: string; address: string) {.
    async: (raises: []).} =
  await emitDeviceDiscoveredMtImpl(brokerCtx, DeviceDiscovered(
      deviceId: deviceId, name: name, deviceType: deviceType, address: address))

proc dropDeviceDiscoveredMtListenerImpl(brokerCtx: BrokerContext;
    handle: DeviceDiscoveredListener) =
  if handle.id == 0'u64:
    return
  if handle.threadId != currentMtThreadId():
    error "dropListener called from wrong thread",
          eventType = "DeviceDiscovered",
          handleThread = repr(handle.threadId),
          currentThread = repr(currentMtThreadId())
    return
  var tvIdx = -1
  for i in 0 ..< gDeviceDiscoveredTvListenerCtxs.len:
    if gDeviceDiscoveredTvListenerCtxs[i] == brokerCtx:
      tvIdx = i
      break
  if tvIdx < 0:
    return
  gDeviceDiscoveredTvListenerHandlers[tvIdx].del(handle.id)
  if gDeviceDiscoveredTvListenerHandlers[tvIdx].len == 0:
    gDeviceDiscoveredTvListenerCtxs.del(tvIdx)
    gDeviceDiscoveredTvListenerHandlers.del(tvIdx)
    gDeviceDiscoveredTvNextIds.del(tvIdx)
    let myThreadId = currentMtThreadId()
    let myThreadGen = currentMtThreadGen()
    withLock(gDeviceDiscoveredMtLock):
      for i in 0 ..< gDeviceDiscoveredMtBucketCount:
        if gDeviceDiscoveredMtBuckets[i].brokerCtx ==
            brokerCtx and
            gDeviceDiscoveredMtBuckets[i].threadId ==
            myThreadId and
            gDeviceDiscoveredMtBuckets[i].threadGen ==
            myThreadGen:
          gDeviceDiscoveredMtBuckets[i].hasListeners = false
          break

proc dropAllDeviceDiscoveredMtListenersImpl(brokerCtx: BrokerContext) =
  ensureInitDeviceDiscoveredMtBroker()
  let myThreadId = currentMtThreadId()
  var chansToClear: seq[ptr AsyncChannel[DeviceDiscoveredMtEventMsg]] = @[]
  withLock(gDeviceDiscoveredMtLock):
    for i in 0 ..< gDeviceDiscoveredMtBucketCount:
      if gDeviceDiscoveredMtBuckets[i].brokerCtx ==
          brokerCtx and
          gDeviceDiscoveredMtBuckets[i].hasListeners:
        gDeviceDiscoveredMtBuckets[i].hasListeners = false
        if gDeviceDiscoveredMtBuckets[i].threadId !=
            myThreadId:
          chansToClear.add(gDeviceDiscoveredMtBuckets[i].eventChan)
  var tvIdx = -1
  for i in 0 ..< gDeviceDiscoveredTvListenerCtxs.len:
    if gDeviceDiscoveredTvListenerCtxs[i] == brokerCtx:
      tvIdx = i
      break
  if tvIdx >= 0:
    gDeviceDiscoveredTvListenerHandlers[tvIdx].clear()
    gDeviceDiscoveredTvListenerCtxs.del(tvIdx)
    gDeviceDiscoveredTvListenerHandlers.del(tvIdx)
    gDeviceDiscoveredTvNextIds.del(tvIdx)
  for chan in chansToClear:
    chan[].sendSync(DeviceDiscoveredMtEventMsg(
        kind: DeviceDiscoveredMtEventMsgKind.emkClearListeners))

proc dropListener*(_: typedesc[DeviceDiscovered];
                   handle: DeviceDiscoveredListener) =
  dropDeviceDiscoveredMtListenerImpl(DefaultBrokerContext, handle)

proc dropListener*(_: typedesc[DeviceDiscovered];
                   brokerCtx: BrokerContext;
                   handle: DeviceDiscoveredListener) =
  dropDeviceDiscoveredMtListenerImpl(brokerCtx, handle)

proc dropAllListeners*(_: typedesc[DeviceDiscovered]) =
  dropAllDeviceDiscoveredMtListenersImpl(DefaultBrokerContext)

proc dropAllListeners*(_: typedesc[DeviceDiscovered];
                       brokerCtx: BrokerContext) =
  dropAllDeviceDiscoveredMtListenersImpl(brokerCtx)

const
  DeviceDiscoveredApiTypeId* = 1
type
  DeviceDiscoveredCCallback* = proc (deviceId: int64; name: cstring;
                                     deviceType: cstring; address: cstring) {.
      cdecl.}
var gDeviceDiscoveredApiListenerHandles {.threadvar.}: seq[
    DeviceDiscoveredListener]
proc registerDeviceDiscoveredCallback(ctx: BrokerContext;
                                      callbackPtr: pointer): Result[
    RegisterEventListenerResult, string] =
  let cb_587238111 = cast[DeviceDiscoveredCCallback](callbackPtr)
  let wrapper: DeviceDiscoveredListenerProc = proc (
      evt_587238110: DeviceDiscovered): Future[void] {.async: (raises: []).} =
    when defined(brokerDebug):
      debugEcho "[API-EVENT] Entering wrapper, cb isNil=", cb_587238111.isNil()
    let c_name_587238112 = allocSharedCString(evt_587238110.name)
    let c_deviceType_587238113 = allocSharedCString(evt_587238110.deviceType)
    let c_address_587238114 = allocSharedCString(evt_587238110.address)
    when defined(brokerDebug):
      debugEcho "[API-EVENT] post-alloc, calling cb"
    {.gcsafe.}:
      try:
        cb_587238111(evt_587238110.deviceId, c_name_587238112, c_deviceType_587238113,
                     c_address_587238114)
      except Exception:
        when defined(brokerDebug):
          debugEcho "[API-EVENT] Callback exception: ", getCurrentExceptionMsg()
        discard
    when defined(brokerDebug):
      debugEcho "[API-EVENT] cb done, freeing"
    freeSharedCString(c_name_587238112)
    freeSharedCString(c_deviceType_587238113)
    freeSharedCString(c_address_587238114)
  let listenRes = DeviceDiscovered.listen(ctx,
      wrapper)
  if listenRes.isOk():
    gDeviceDiscoveredApiListenerHandles.add(listenRes.get())
    return ok(RegisterEventListenerResult(handle: listenRes.get().id,
        success: true))
  else:
    return err(listenRes.error())

proc unregisterDeviceDiscoveredCallback(ctx: BrokerContext;
                                        targetId: uint64): Result[
    RegisterEventListenerResult, string] =
  for i in 0 ..< gDeviceDiscoveredApiListenerHandles.len:
    if gDeviceDiscoveredApiListenerHandles[i].id ==
        targetId:
      DeviceDiscovered.dropListener(ctx, gDeviceDiscoveredApiListenerHandles[
          i])
      gDeviceDiscoveredApiListenerHandles.del(i)
      return ok(RegisterEventListenerResult(handle: targetId,
          success: true))
  return err("Handle not found")

proc unregisterAllDeviceDiscoveredCallbacks(ctx: BrokerContext): Result[
    RegisterEventListenerResult, string] =
  for h in gDeviceDiscoveredApiListenerHandles:
    DeviceDiscovered.dropListener(ctx, h)
  gDeviceDiscoveredApiListenerHandles.setLen(0)
  return ok(RegisterEventListenerResult(handle: 0'u64, success: true))

proc handleDeviceDiscoveredRegistration(ctx: BrokerContext;
                                        action: int32;
                                        callbackPtr: pointer;
                                        listenerHandle: uint64): Future[
    Result[RegisterEventListenerResult, string]] {.async: (raises: []).} =
  case action
  of 0:
    return registerDeviceDiscoveredCallback(ctx,
        callbackPtr)
  of 1:
    return unregisterDeviceDiscoveredCallback(ctx,
        listenerHandle)
  of 2:
    return unregisterAllDeviceDiscoveredCallbacks(ctx)
  else:
    return err("Unknown action: " & $action)

proc cleanupDeviceDiscoveredListeners(ctx: BrokerContext) =
  DeviceDiscovered.dropAllListeners(ctx)

proc onDeviceDiscovered(ctx: uint32;
                        callback: DeviceDiscoveredCCallback): uint64 {.
    exportc: "onDeviceDiscovered", cdecl, dynlib.} =
  let res = waitFor RegisterEventListenerResult.request(
      BrokerContext(ctx), 0'i32, int32(DeviceDiscoveredApiTypeId),
      cast[pointer](callback), 0'u64)
  if res.isOk():
    res.get().handle
  else:
    0'u64

proc offDeviceDiscovered(ctx: uint32; handle: uint64) {.
    exportc: "offDeviceDiscovered", cdecl, dynlib.} =
  if handle == 0'u64:
    discard waitFor RegisterEventListenerResult.request(
        BrokerContext(ctx), 2'i32, int32(DeviceDiscoveredApiTypeId),
        nil, 0'u64)
  else:
    discard waitFor RegisterEventListenerResult.request(
        BrokerContext(ctx), 1'i32, int32(DeviceDiscoveredApiTypeId),
        nil, handle)

when not compiles(typeof(InitializeRequest)):
  {.error: "registerBrokerLibrary: initializeRequest type \'" &
      astToStr(InitializeRequest) &
      "\' is not defined. Ensure a RequestBroker(API) declaring this type " &
      "appears before registerBrokerLibrary.".}
when not compiles(typeof(ShutdownRequest)):
  {.error: "registerBrokerLibrary: shutdownRequest type \'" &
      astToStr(ShutdownRequest) &
      "\' is not defined. Ensure a RequestBroker(API) declaring this type " &
      "appears before registerBrokerLibrary.".}
# ===== registerBrokerLibrary: "mylib" =====
## Flow:
## - This section assembles the full shared-library runtime around the generated brokers.
## - `createContext` allocates state, starts delivery and processing threads, waits for startup readiness, and returns the context handle.
## - `shutdown` cleans listeners/providers, signals worker threads, releases startup state, and frees per-context resources.
type
  mylibStartupState = object
    deliveryReady: Atomic[int]
    processingReady: Atomic[int]
    deliveryErrorMessage: cstring
    processingErrorMessage: cstring
  mylibProcThreadArg = object
    ctx: BrokerContext
    shutdownFlag: Atomic[int]
    startupState: ptr mylibStartupState
  mylibDelivThreadArg = object
    ctx: BrokerContext
    shutdownFlag: Atomic[int]
    startupState: ptr mylibStartupState
  mylibCtxEntry = object
    ctx: BrokerContext
    procThread: Thread[ptr mylibProcThreadArg]
    delivThread: Thread[ptr mylibDelivThreadArg]
    procArg: ptr mylibProcThreadArg
    delivArg: ptr mylibDelivThreadArg
    active: bool
proc mylibNimMain() {.importc: "mylibNimMain", cdecl.}
var gmylibNimInitialized: Atomic[int]
proc mylib_initialize(): Result[void, string] =
  while true:
    case gmylibNimInitialized.load(moAcquire)
    of 2:
      return ok()
    of -1:
      return err("Failed to initialize Nim runtime")
    of 1:
      sleep(1)
    else:
      var expected = 0
      if gmylibNimInitialized.compareExchange(expected, 1, moAcquire,
          moRelaxed):
        when compileOption("app", "lib"):
          let initRes = catch do:
            mylibNimMain()
            when declared(setupForeignThreadGc):
              setupForeignThreadGc()
            when declared(nimGC_setStackBottom):
              var locals {.volatile, noinit.}: pointer
              locals = addr(locals)
              nimGC_setStackBottom(locals)
          if initRes.isErr():
            error "Failed to initialize Nim runtime", library = "mylib",
                  detail = initRes.error.msg
            gmylibNimInitialized.store(-1, moRelease)
            return err("Failed to initialize Nim runtime")
        gmylibNimInitialized.store(2, moRelease)
        return ok()

type
  mylibCreateContextResult* {.exportc.} = object
    ctx*: uint32
    error_message*: cstring
proc free_mylib_create_context_result(r: ptr mylibCreateContextResult) {.
    exportc: "free_mylib_create_context_result", cdecl, dynlib.} =
  if r.isNil:
    return
  if not r.error_message.isNil:
    freeCString(r.error_message)
    r.error_message = nil

var gmylibCtxs: seq[ptr mylibCtxEntry]
var gmylibCtxsLock: Lock
var gmylibCtxsInit: Atomic[int]
proc ensureLibCtxInit(): Result[void, string] =
  let initRes = mylib_initialize()
  if initRes.isErr():
    return err(initRes.error())
  if gmylibCtxsInit.load(moRelaxed) == 2:
    return ok()
  var expected = 0
  if gmylibCtxsInit.compareExchange(expected, 1, moAcquire, moRelaxed):
    initLock(gmylibCtxsLock)
    gmylibCtxs = @[]
    gmylibCtxsInit.store(2, moRelease)
  else:
    while gmylibCtxsInit.load(moAcquire) != 2:
      discard
  ok()

proc cleanupStartupState(startupState: ptr mylibStartupState) =
  if startupState.isNil:
    return
  if not startupState.deliveryErrorMessage.isNil:
    freeCString(startupState.deliveryErrorMessage)
    startupState.deliveryErrorMessage = nil
  if not startupState.processingErrorMessage.isNil:
    freeCString(startupState.processingErrorMessage)
    startupState.processingErrorMessage = nil
  deallocShared(startupState)

proc releaseCtxEntryResources(entryPtr: ptr mylibCtxEntry) =
  if entryPtr.isNil:
    return
  if not entryPtr.procArg.isNil:
    deallocShared(entryPtr.procArg)
  if not entryPtr.delivArg.isNil:
    deallocShared(entryPtr.delivArg)
  deallocShared(entryPtr)

proc releaseCreateContextResources(startupState: ptr mylibStartupState;
                                   procArg: ptr mylibProcThreadArg;
    delivArg: ptr mylibDelivThreadArg;
                                   entryPtr: ptr mylibCtxEntry) =
  cleanupStartupState(startupState)
  if not entryPtr.isNil:
    releaseCtxEntryResources(entryPtr)
    return
  if not procArg.isNil:
    deallocShared(procArg)
  if not delivArg.isNil:
    deallocShared(delivArg)

proc recordStartupFailure(startupFlag: ptr Atomic[int];
                          errorMessage: ptr cstring;
                          stage: string; detail: string) =
  error "Library context startup failed", library = "mylib",
        stage = stage, detail = detail
  if not errorMessage[].isNil:
    freeCString(errorMessage[])
  errorMessage[] = allocCStringCopy(detail)
  startupFlag[].store(-1, moRelease)

proc installEventListenerProvider(ctx: BrokerContext): Result[void,
    string] =
  let providerInstallRes = RegisterEventListenerResult.setProvider(
      ctx, proc (action: int32; eventTypeId: int32;
                           callbackPtr: pointer; listenerHandle: uint64): Future[
      Result[RegisterEventListenerResult, string]] {.closure, async.} =
    case eventTypeId
    of 0'i32:
      return await(handleDeviceStatusChangedRegistration(ctx, action,
          callbackPtr, listenerHandle))
    of 1'i32:
      return await(handleDeviceDiscoveredRegistration(ctx, action,
          callbackPtr, listenerHandle))
    else:
      return err("Unknown event type: " & `$`(eventTypeId)))
  if providerInstallRes.isErr():
    return err(providerInstallRes.error())
  return ok()

proc cleanupAllApiEventListeners(ctx: BrokerContext) =
  cleanupDeviceStatusChangedListeners(ctx)
  cleanupDeviceDiscoveredListeners(ctx)

proc cleanupAllApiRequestProviders(ctx: BrokerContext) =
  cleanupApiRequestProvider_InitializeRequest(ctx)
  cleanupApiRequestProvider_ShutdownRequest(ctx)
  cleanupApiRequestProvider_AddDevice(ctx)
  cleanupApiRequestProvider_RemoveDevice(ctx)
  cleanupApiRequestProvider_GetDevice(ctx)
  cleanupApiRequestProvider_ListDevices(ctx)

proc waitFormylibStartup(startupFlag: ptr Atomic[int];
                         timeoutMs: int): int =
  var waitedMs = 0
  while true:
    let startupStatus = startupFlag[].load(moAcquire)
    if startupStatus != 0:
      return startupStatus
    if waitedMs >= timeoutMs:
      return 0
    sleep(1)
    inc waitedMs

proc mylibProcessingThread(arg: ptr mylibProcThreadArg) {.thread.} =
  setThreadBrokerContext(arg.ctx)
  when compiles(setupProviders(arg.ctx).isErr()):
    let setupCatchRes = catch do:
      setupProviders(arg.ctx)
    if setupCatchRes.isErr():
      recordStartupFailure(addr arg.startupState.processingReady, addr
          arg.startupState.processingErrorMessage,
                           "request processing startup", "setupProviders raised exception: " &
          setupCatchRes.error.msg)
      return
    let setupRes = setupCatchRes.get()
    if setupRes.isErr():
      recordStartupFailure(addr arg.startupState.processingReady, addr
          arg.startupState.processingErrorMessage,
                           "request processing startup",
                           setupRes.error())
      return
  elif compiles(setupProviders(arg.ctx)):
    let setupCatchRes = catch do:
      setupProviders(arg.ctx)
    if setupCatchRes.isErr():
      recordStartupFailure(addr arg.startupState.processingReady, addr
          arg.startupState.processingErrorMessage,
                           "request processing startup", "setupProviders raised exception: " &
          setupCatchRes.error.msg)
      return
  arg.startupState.processingReady.store(1, moRelease)
  proc awaitShutdown(shutdownFlag: ptr Atomic[int]) {.
      async: (raises: []).} =
    while shutdownFlag[].load(moAcquire) != 1:
      let sleepRes = catch do:
        await sleepAsync(milliseconds(1))
      if sleepRes.isErr():
        discard

  proc drainAsyncOps() {.async: (raises: []).} =
    let sleepRes = catch do:
      await sleepAsync(milliseconds(1))
    if sleepRes.isErr():
      discard

  waitFor awaitShutdown(addr arg.shutdownFlag)
  cleanupAllApiRequestProviders(arg.ctx)
  waitFor drainAsyncOps()

proc mylibDeliveryThread(arg: ptr mylibDelivThreadArg) {.thread.} =
  setThreadBrokerContext(arg.ctx)
  let installProviderRes = installEventListenerProvider(
      arg.ctx)
  if installProviderRes.isErr():
    recordStartupFailure(addr arg.startupState.deliveryReady,
                         addr arg.startupState.deliveryErrorMessage,
                         "event delivery startup",
                         installProviderRes.error())
    return
  arg.startupState.deliveryReady.store(1, moRelease)
  proc awaitShutdown(shutdownFlag: ptr Atomic[int]) {.
      async: (raises: []).} =
    while shutdownFlag[].load(moAcquire) != 1:
      let sleepRes = catch do:
        await sleepAsync(milliseconds(1))
      if sleepRes.isErr():
        discard

  waitFor awaitShutdown(addr arg.shutdownFlag)
  cleanupAllApiEventListeners(arg.ctx)

proc mylib_createContext(): mylibCreateContextResult {.
    exportc: "mylib_createContext", cdecl, dynlib.} =
  result.ctx = 0'u32
  result.error_message = nil
  let initRes = ensureLibCtxInit()
  if initRes.isErr():
    result.error_message = allocCStringCopy(initRes.error())
    return
  var ctx = NewBrokerContext()
  if uint32(ctx) == 0:
    ctx = NewBrokerContext()
  var startupState: ptr mylibStartupState = nil
  var procArg: ptr mylibProcThreadArg = nil
  var delivArg: ptr mylibDelivThreadArg = nil
  var entry: ptr mylibCtxEntry = nil
  try:
    startupState = cast[ptr mylibStartupState](createShared(
        mylibStartupState, 1))
  except ResourceExhaustedError:
    error "Failed to allocate createContext startup state", library = "mylib",
          ctx = uint32(ctx), detail = "resource exhaustion"
    result.error_message = allocCStringCopy(
        "Library context creation failed during startup preparation")
    return
  except Exception as e:
    error "Failed to allocate createContext startup state", library = "mylib",
          ctx = uint32(ctx), detail = e.msg
    result.error_message = allocCStringCopy(
        "Library context creation failed during startup preparation")
    return
  startupState.deliveryReady.store(0, moRelease)
  startupState.processingReady.store(0, moRelease)
  startupState.deliveryErrorMessage = nil
  startupState.processingErrorMessage = nil
  try:
    procArg = cast[ptr mylibProcThreadArg](createShared(
        mylibProcThreadArg, 1))
  except ResourceExhaustedError:
    error "Failed to allocate processing-thread startup arguments",
          library = "mylib", ctx = uint32(ctx),
          detail = "resource exhaustion"
    releaseCreateContextResources(startupState, procArg,
                                  delivArg, entry)
    result.error_message = allocCStringCopy(
        "Library context creation failed during startup preparation")
    return
  except Exception as e:
    error "Failed to allocate processing-thread startup arguments",
          library = "mylib", ctx = uint32(ctx),
          detail = e.msg
    releaseCreateContextResources(startupState, procArg,
                                  delivArg, entry)
    result.error_message = allocCStringCopy(
        "Library context creation failed during startup preparation")
    return
  procArg.ctx = ctx
  procArg.shutdownFlag.store(0, moRelease)
  procArg.startupState = startupState
  try:
    delivArg = cast[ptr mylibDelivThreadArg](createShared(
        mylibDelivThreadArg, 1))
  except ResourceExhaustedError:
    error "Failed to allocate delivery-thread startup arguments",
          library = "mylib", ctx = uint32(ctx),
          detail = "resource exhaustion"
    releaseCreateContextResources(startupState, procArg,
                                  delivArg, entry)
    result.error_message = allocCStringCopy(
        "Library context creation failed during startup preparation")
    return
  except Exception as e:
    error "Failed to allocate delivery-thread startup arguments",
          library = "mylib", ctx = uint32(ctx),
          detail = e.msg
    releaseCreateContextResources(startupState, procArg,
                                  delivArg, entry)
    result.error_message = allocCStringCopy(
        "Library context creation failed during startup preparation")
    return
  delivArg.ctx = ctx
  delivArg.shutdownFlag.store(0, moRelease)
  delivArg.startupState = startupState
  try:
    entry = cast[ptr mylibCtxEntry](createShared(mylibCtxEntry, 1))
  except ResourceExhaustedError:
    error "Failed to allocate library context entry", library = "mylib",
          ctx = uint32(ctx), detail = "resource exhaustion"
    releaseCreateContextResources(startupState, procArg,
                                  delivArg, entry)
    result.error_message = allocCStringCopy(
        "Library context creation failed during startup preparation")
    return
  except Exception as e:
    error "Failed to allocate library context entry", library = "mylib",
          ctx = uint32(ctx), detail = e.msg
    releaseCreateContextResources(startupState, procArg,
                                  delivArg, entry)
    result.error_message = allocCStringCopy(
        "Library context creation failed during startup preparation")
    return
  entry.ctx = ctx
  entry.procArg = procArg
  entry.delivArg = delivArg
  entry.active = true
  try:
    createThread(entry.delivThread, mylibDeliveryThread,
                 delivArg)
  except ResourceExhaustedError:
    error "Failed to create delivery thread", library = "mylib",
          ctx = uint32(ctx), detail = "resource exhaustion"
    releaseCreateContextResources(startupState, procArg,
                                  delivArg, entry)
    result.error_message = allocCStringCopy(
        "Library context creation failed during event delivery startup")
    return
  except Exception as e:
    error "Failed to create delivery thread", library = "mylib",
          ctx = uint32(ctx), detail = e.msg
    releaseCreateContextResources(startupState, procArg,
                                  delivArg, entry)
    result.error_message = allocCStringCopy(
        "Library context creation failed during event delivery startup")
    return
  let deliveryStartupStatus = waitFormylibStartup(
      addr startupState.deliveryReady, 5000)
  if deliveryStartupStatus != 1:
    delivArg.shutdownFlag.store(1, moRelease)
    joinThread(entry.delivThread)
    if deliveryStartupStatus == -1:
      error "Event delivery startup reported failure", library = "mylib",
            ctx = uint32(ctx), detail = if startupState.deliveryErrorMessage.isNil:
        "no additional detail"
      else:
        $startupState.deliveryErrorMessage
      result.error_message = allocCStringCopy(
          "Library context creation failed during event delivery startup")
    else:
      error "Event delivery startup timed out", library = "mylib",
            ctx = uint32(ctx), timeout_ms = 5000
      result.error_message = allocCStringCopy(
          "Library context creation timed out during event delivery startup")
    releaseCreateContextResources(startupState, procArg,
                                  delivArg, entry)
    return
  try:
    createThread(entry.procThread, mylibProcessingThread,
                 procArg)
  except ResourceExhaustedError:
    delivArg.shutdownFlag.store(1, moRelease)
    joinThread(entry.delivThread)
    error "Failed to create processing thread", library = "mylib",
          ctx = uint32(ctx), detail = "resource exhaustion"
    releaseCreateContextResources(startupState, procArg,
                                  delivArg, entry)
    result.error_message = allocCStringCopy(
        "Library context creation failed during request processing startup")
    return
  except Exception as e:
    error "Failed to create processing thread", library = "mylib",
          ctx = uint32(ctx), detail = e.msg
    delivArg.shutdownFlag.store(1, moRelease)
    joinThread(entry.delivThread)
    releaseCreateContextResources(startupState, procArg,
                                  delivArg, entry)
    result.error_message = allocCStringCopy(
        "Library context creation failed during request processing startup")
    return
  let processingStartupStatus = waitFormylibStartup(
      addr startupState.processingReady, 5000)
  if processingStartupStatus != 1:
    procArg.shutdownFlag.store(1, moRelease)
    delivArg.shutdownFlag.store(1, moRelease)
    joinThread(entry.procThread)
    joinThread(entry.delivThread)
    if processingStartupStatus == -1:
      error "Request processing startup reported failure", library = "mylib",
            ctx = uint32(ctx), detail = if startupState.processingErrorMessage.isNil:
        "no additional detail"
      else:
        $startupState.processingErrorMessage
      result.error_message = allocCStringCopy(
          "Library context creation failed during request processing startup")
    else:
      error "Request processing startup timed out", library = "mylib",
            ctx = uint32(ctx), timeout_ms = 5000
      result.error_message = allocCStringCopy("Library context creation timed out during request processing startup")
    releaseCreateContextResources(startupState, procArg,
                                  delivArg, entry)
    return
  cleanupStartupState(startupState)
  withLock(gmylibCtxsLock):
    gmylibCtxs.add(entry)
  result.ctx = uint32(ctx)

proc mylib_shutdown(ctx: uint32) {.exportc: "mylib_shutdown", cdecl,
    dynlib.} =
  let initRes = ensureLibCtxInit()
  if initRes.isErr():
    error "Library shutdown skipped because initialization failed",
          library = "mylib", ctx = ctx,
          detail = initRes.error()
    return
  let brokerCtx = BrokerContext(ctx)
  var entryPtr: ptr mylibCtxEntry = nil
  withLock(gmylibCtxsLock):
    for i in 0 ..< gmylibCtxs.len:
      let candidate = gmylibCtxs[i]
      if candidate.isNil:
        continue
      if candidate.ctx == brokerCtx and
          candidate.active:
        entryPtr = candidate
        entryPtr.active = false
        gmylibCtxs[i] = nil
        break
  if entryPtr.isNil:
    return
  let shutdownRes = waitFor ShutdownRequest.request(
      brokerCtx)
  if shutdownRes.isErr():
    error "Library shutdown request failed", library = "mylib",
          ctx = ctx, detail = shutdownRes.error()
  entryPtr.delivArg.shutdownFlag.store(1, moRelease)
  joinThread(entryPtr.delivThread)
  entryPtr.procArg.shutdownFlag.store(1, moRelease)
  joinThread(entryPtr.procThread)
  cleanupAllApiRequestProviders(brokerCtx)
  withLock(gmylibCtxsLock):
    var writeIdx = 0
    for i in 0 ..< gmylibCtxs.len:
      let candidate = gmylibCtxs[i]
      if candidate.isNil:
        continue
      gmylibCtxs[writeIdx] = candidate
      inc writeIdx
    gmylibCtxs.setLen(writeIdx)
  releaseCtxEntryResources(entryPtr)

proc mylib_free_string(s: cstring) {.exportc: "mylib_free_string",
    cdecl, dynlib.} =
  freeCString(s)

proc mylib_free_initialize_result*(r: ptr InitializeRequestCResult) {.
    exportc: "mylib_free_initialize_result", cdecl, dynlib.} =
  free_initialize_result(r)

proc mylib_initialize*(ctx: uint32; configPath: cstring): InitializeRequestCResult {.
    exportc: "mylib_initialize", cdecl, dynlib.} =
  return initialize(ctx, configPath)

proc mylib_free_add_device_result*(r: ptr AddDeviceCResult) {.
    exportc: "mylib_free_add_device_result", cdecl, dynlib.} =
  free_add_device_result(r)

proc mylib_add_device*(ctx: uint32; devices: pointer; devices_count: cint): AddDeviceCResult {.
    exportc: "mylib_add_device", cdecl, dynlib.} =
  return add_device(ctx, devices, devices_count)

proc mylib_free_remove_device_result*(r: ptr RemoveDeviceCResult) {.
    exportc: "mylib_free_remove_device_result", cdecl, dynlib.} =
  free_remove_device_result(r)

proc mylib_remove_device*(ctx: uint32; deviceId: int64): RemoveDeviceCResult {.
    exportc: "mylib_remove_device", cdecl, dynlib.} =
  return remove_device(ctx, deviceId)

proc mylib_free_get_device_result*(r: ptr GetDeviceCResult) {.
    exportc: "mylib_free_get_device_result", cdecl, dynlib.} =
  free_get_device_result(r)

proc mylib_get_device*(ctx: uint32; deviceId: int64): GetDeviceCResult {.
    exportc: "mylib_get_device", cdecl, dynlib.} =
  return get_device(ctx, deviceId)

proc mylib_free_list_devices_result*(r: ptr ListDevicesCResult) {.
    exportc: "mylib_free_list_devices_result", cdecl, dynlib.} =
  free_list_devices_result(r)

proc mylib_list_devices*(ctx: uint32): ListDevicesCResult {.
    exportc: "mylib_list_devices", cdecl, dynlib.} =
  return list_devices(ctx)

proc mylib_onDeviceStatusChanged*(ctx: uint32;
                                  callback: DeviceStatusChangedCCallback): uint64 {.
    exportc: "mylib_onDeviceStatusChanged", cdecl, dynlib.} =
  return onDeviceStatusChanged(ctx, callback)

proc mylib_offDeviceStatusChanged*(ctx: uint32; handle: uint64) {.
    exportc: "mylib_offDeviceStatusChanged", cdecl, dynlib.} =
  offDeviceStatusChanged(ctx, handle)

proc mylib_onDeviceDiscovered*(ctx: uint32; callback: DeviceDiscoveredCCallback): uint64 {.
    exportc: "mylib_onDeviceDiscovered", cdecl, dynlib.} =
  return onDeviceDiscovered(ctx, callback)

proc mylib_offDeviceDiscovered*(ctx: uint32; handle: uint64) {.
