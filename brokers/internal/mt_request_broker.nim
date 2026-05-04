## Multi-Thread RequestBroker
## --------------------------
## Generates a multi-thread capable RequestBroker where the provider runs on the
## thread that called `setProvider` (which must keep its chronos event loop running),
## and requests from other threads are routed via Channel[T] + per-thread shared signal.
##
## Same-thread requests bypass channels and call the provider directly.
##
## The broker does NOT own or spawn threads — that is the user's responsibility.
## The global registry uses `createShared` / raw pointers so it is safe under
## both `--mm:orc` and `--mm:refc`.
##
## Provider closures are stored in threadvars (GC-managed, per-thread) rather
## than in the shared bucket, avoiding the need to cast closures to raw pointers.

{.push raises: [].}

import std/[macros, strutils, locks, os]
import chronos, chronicles
import results
import ./helper/broker_utils, ../broker_context

import ./mt_broker_common
export results, chronos, chronicles, broker_context, mt_broker_common

# ---------------------------------------------------------------------------
# Macro code generator
# ---------------------------------------------------------------------------

proc isAsyncReturnTypeValid(returnType, typeIdent: NimNode): bool =
  if returnType.kind != nnkBracketExpr or returnType.len != 2:
    return false
  if returnType[0].kind != nnkIdent or not returnType[0].eqIdent("Future"):
    return false
  let inner = returnType[1]
  if inner.kind != nnkBracketExpr or inner.len != 3:
    return false
  if inner[0].kind != nnkIdent or not inner[0].eqIdent("Result"):
    return false
  if inner[1].kind != nnkIdent or not inner[1].eqIdent($typeIdent):
    return false
  inner[2].kind == nnkIdent and inner[2].eqIdent("string")

proc generateMtRequestBroker*(body: NimNode): NimNode =
  when defined(brokerDebug):
    echo body.treeRepr
    echo "RequestBroker mode: mt"

  let parsed = parseSingleTypeDef(body, "RequestBroker", allowRefToNonObject = true)
  let typeIdent = parsed.typeIdent
  let objectDef = parsed.objectDef

  let exportedTypeIdent = postfix(copyNimTree(typeIdent), "*")
  let typeDisplayName = sanitizeIdentName(typeIdent)
  let typeNameLit = newLit(typeDisplayName)

  # ── Parse signatures ────────────────────────────────────────────────
  var zeroArgSig: NimNode = nil
  var zeroArgProviderName: NimNode = nil
  var argSig: NimNode = nil
  var argParams: seq[NimNode] = @[]
  var argProviderName: NimNode = nil

  for stmt in body:
    case stmt.kind
    of nnkProcDef:
      let procName = stmt[0]
      let procNameIdent =
        case procName.kind
        of nnkIdent:
          procName
        of nnkPostfix:
          procName[1]
        else:
          procName
      if not ($procNameIdent).startsWith("signature"):
        error("Signature proc names must start with `signature`", procName)
      let params = stmt.params
      if params.len == 0:
        error("Signature must declare a return type", stmt)
      let returnType = params[0]
      if not isAsyncReturnTypeValid(returnType, typeIdent):
        error(
          "MT RequestBroker signature must return Future[Result[`" & $typeIdent &
            "`, string]]",
          stmt,
        )
      let paramCount = params.len - 1
      if paramCount == 0:
        if zeroArgSig != nil:
          error("Only one zero-argument signature is allowed", stmt)
        zeroArgSig = stmt
        zeroArgProviderName = ident(typeDisplayName & "ProviderNoArgs")
      elif paramCount >= 1:
        if argSig != nil:
          error("Only one argument-based signature is allowed", stmt)
        argSig = stmt
        argParams = @[]
        for idx in 1 ..< params.len:
          let paramDef = params[idx]
          if paramDef.kind != nnkIdentDefs:
            error(
              "Signature parameter must be a standard identifier declaration", paramDef
            )
          let paramTypeNode = paramDef[paramDef.len - 2]
          if paramTypeNode.kind == nnkEmpty:
            error("Signature parameter must declare a type", paramDef)
          argParams.add(copyNimTree(paramDef))
        argProviderName = ident(typeDisplayName & "ProviderWithArgs")
    of nnkTypeSection, nnkEmpty:
      discard
    else:
      error("Unsupported statement inside RequestBroker definition", stmt)

  # If no signatures at all, generate a zero-arg default.
  if zeroArgSig.isNil() and argSig.isNil():
    zeroArgSig = newEmptyNode()
    zeroArgProviderName = ident(typeDisplayName & "ProviderNoArgs")

  # ── Result type ─────────────────────────────────────────────────────
  let returnType = quote:
    Future[Result[`typeIdent`, string]]

  # ── Build type section ──────────────────────────────────────────────
  var typeSection = newTree(nnkTypeSection)
  typeSection.add(newTree(nnkTypeDef, exportedTypeIdent, newEmptyNode(), objectDef))

  # Provider proc types
  proc makeProcType(returnType: NimNode, params: seq[NimNode]): NimNode =
    var formal = newTree(nnkFormalParams)
    formal.add(returnType)
    for param in params:
      formal.add(param)
    let pragmas = newTree(nnkPragma, ident("async"))
    newTree(nnkProcTy, formal, pragmas)

  if not zeroArgSig.isNil():
    let procType = makeProcType(returnType, @[])
    typeSection.add(newTree(nnkTypeDef, zeroArgProviderName, newEmptyNode(), procType))
  if not argSig.isNil():
    let procType = makeProcType(returnType, cloneParams(argParams))
    typeSection.add(newTree(nnkTypeDef, argProviderName, newEmptyNode(), procType))

  # ── Request message type ────────────────────────────────────────────
  let requestMsgName = ident(typeDisplayName & "MtRequestMsg")
  var msgRecList = newTree(nnkRecList)
  msgRecList.add(
    newTree(nnkIdentDefs, ident("isShutdown"), ident("bool"), newEmptyNode())
  )
  msgRecList.add(
    newTree(nnkIdentDefs, ident("requestKind"), ident("int"), newEmptyNode())
  )
  if not argSig.isNil():
    for paramDef in argParams:
      for i in 0 ..< paramDef.len - 2:
        let nameNode = paramDef[i]
        if nameNode.kind != nnkEmpty:
          let typeNode = paramDef[paramDef.len - 2]
          msgRecList.add(
            newTree(
              nnkIdentDefs, ident($nameNode), copyNimTree(typeNode), newEmptyNode()
            )
          )
  let responseChanType = quote:
    ptr Channel[Result[`typeIdent`, string]]
  msgRecList.add(
    newTree(nnkIdentDefs, ident("responseChan"), responseChanType, newEmptyNode())
  )
  let requesterSignalType = quote:
    ThreadSignalPtr
  msgRecList.add(
    newTree(nnkIdentDefs, ident("requesterSignal"), requesterSignalType, newEmptyNode())
  )
  typeSection.add(
    newTree(
      nnkTypeDef,
      requestMsgName,
      newEmptyNode(),
      newTree(nnkObjectTy, newEmptyNode(), newEmptyNode(), msgRecList),
    )
  )

  # ── Bucket type (no provider fields — closures live in threadvars) ──
  let bucketName = ident(typeDisplayName & "MtBucket")
  var bucketRecList = newTree(nnkRecList)
  bucketRecList.add(
    newTree(nnkIdentDefs, ident("brokerCtx"), ident("BrokerContext"), newEmptyNode())
  )
  let requestChanPtrType = quote:
    ptr Channel[`requestMsgName`]
  bucketRecList.add(
    newTree(nnkIdentDefs, ident("requestChan"), requestChanPtrType, newEmptyNode())
  )
  let providerSignalType = quote:
    ThreadSignalPtr
  bucketRecList.add(
    newTree(nnkIdentDefs, ident("providerSignal"), providerSignalType, newEmptyNode())
  )
  bucketRecList.add(
    newTree(nnkIdentDefs, ident("threadId"), ident("pointer"), newEmptyNode())
  )
  bucketRecList.add(
    newTree(nnkIdentDefs, ident("threadGen"), ident("uint64"), newEmptyNode())
  )
  typeSection.add(
    newTree(
      nnkTypeDef,
      bucketName,
      newEmptyNode(),
      newTree(nnkObjectTy, newEmptyNode(), newEmptyNode(), bucketRecList),
    )
  )

  result = newStmtList()
  result.add(typeSection)

  # ── Global state ────────────────────────────────────────────────────
  let globalBucketsIdent = ident("g" & typeDisplayName & "MtBuckets")
  let globalBucketCountIdent = ident("g" & typeDisplayName & "MtBucketCount")
  let globalBucketCapIdent = ident("g" & typeDisplayName & "MtBucketCap")
  let globalLockIdent = ident("g" & typeDisplayName & "MtLock")
  let globalInitIdent = ident("g" & typeDisplayName & "MtInit")

  result.add(
    quote do:
      var `globalBucketsIdent`: ptr UncheckedArray[`bucketName`]
      var `globalBucketCountIdent`: int
      var `globalBucketCapIdent`: int
      var `globalLockIdent`: Lock
      var `globalInitIdent`: Atomic[int]
        ## 0 = uninitialised, 1 = initialising, 2 = ready.
        ## CAS(0→1) wins the race; losers spin until 2.
  )

  # ── Init helper (thread-safe via atomic CAS) ─────────────────────────
  let initProcIdent = ident("ensureInit" & typeDisplayName & "MtBroker")
  result.add(
    quote do:
      proc `initProcIdent`() =
        if `globalInitIdent`.load(moRelaxed) == 2:
          return # fast path — already initialised
        var expected = 0
        if `globalInitIdent`.compareExchange(expected, 1, moAcquire, moRelaxed):
          # We won the init race.
          initLock(`globalLockIdent`)
          `globalBucketCapIdent` = 4
          `globalBucketsIdent` = cast[ptr UncheckedArray[`bucketName`]](createShared(
            `bucketName`, `globalBucketCapIdent`
          ))
          `globalBucketCountIdent` = 0
          `globalInitIdent`.store(2, moRelease)
        else:
          # Another thread is initialising — spin until ready.
          while `globalInitIdent`.load(moAcquire) != 2:
            discard

  )

  # ── Grow helper ─────────────────────────────────────────────────────
  let growProcIdent = ident("grow" & typeDisplayName & "MtBuckets")
  result.add(
    quote do:
      proc `growProcIdent`() =
        ## Must be called under lock.
        let newCap = `globalBucketCapIdent` * 2
        let newBuf =
          cast[ptr UncheckedArray[`bucketName`]](createShared(`bucketName`, newCap))
        for i in 0 ..< `globalBucketCountIdent`:
          newBuf[i] = `globalBucketsIdent`[i]
        # Intentional leak: see equivalent comment in mt_event_broker.nim grow.
        `globalBucketsIdent` = newBuf
        `globalBucketCapIdent` = newCap

  )

  # ── Cross-thread request timeout ──────────────────────────────────
  let timeoutVarIdent = ident("g" & typeDisplayName & "MtRequestTimeout")
  result.add(
    quote do:
      var `timeoutVarIdent`*: Duration = chronos.seconds(5)
        ## Default timeout for cross-thread requests. Same-thread requests
        ## bypass this (they call the provider directly).
        ## NOTE: Set during initialization before spawning worker threads.
        ## Reading from multiple threads is safe on x86-64 (aligned int64),
        ## but concurrent writes are not guaranteed atomic on all platforms.

      proc setRequestTimeout*(_: typedesc[`typeIdent`], timeout: Duration) =
        ## Set the cross-thread request timeout for this broker type.
        ## Call this during initialization before spawning worker threads.
        `timeoutVarIdent` = timeout

      proc requestTimeout*(_: typedesc[`typeIdent`]): Duration =
        ## Get the current cross-thread request timeout for this broker type.
        `timeoutVarIdent`

  )

  # ── Threadvar provider storage ──────────────────────────────────────
  # Closures are GC-managed, so they must live in threadvars (per-thread,
  # GC-visible) rather than in createShared memory.  Two parallel seqs
  # per provider kind: one for BrokerContext keys, one for handlers.

  var tvNoArgCtxIdent, tvNoArgHandlerIdent: NimNode
  if not zeroArgSig.isNil():
    tvNoArgCtxIdent = ident("g" & typeDisplayName & "TvNoArgCtxs")
    tvNoArgHandlerIdent = ident("g" & typeDisplayName & "TvNoArgHandlers")
    result.add(
      quote do:
        var `tvNoArgCtxIdent` {.threadvar.}: seq[BrokerContext]
        var `tvNoArgHandlerIdent` {.threadvar.}: seq[`zeroArgProviderName`]
    )

  var tvWithArgCtxIdent, tvWithArgHandlerIdent: NimNode
  if not argSig.isNil():
    tvWithArgCtxIdent = ident("g" & typeDisplayName & "TvWithArgCtxs")
    tvWithArgHandlerIdent = ident("g" & typeDisplayName & "TvWithArgHandlers")
    result.add(
      quote do:
        var `tvWithArgCtxIdent` {.threadvar.}: seq[BrokerContext]
        var `tvWithArgHandlerIdent` {.threadvar.}: seq[`argProviderName`]
    )

  # ── Per-message reply helper ────────────────────────────────────────
  # Sends a response to the requester via Channel[T] and wakes the requester's
  # dispatcher signal.  No file descriptors consumed — Channel[T] is mutex/condvar.
  let sendReplyIdent = ident("sendReply" & typeDisplayName)
  result.add(
    quote do:
      proc `sendReplyIdent`(
          responseChan: ptr Channel[Result[`typeIdent`, string]],
          requesterSignal: ThreadSignalPtr,
          resp: Result[`typeIdent`, string],
      ) {.gcsafe, raises: [].} =
        {.cast(gcsafe).}:
          try:
            responseChan[].send(resp)
          except Exception:
            discard
        if not requesterSignal.isNil:
          fireBrokerSignal(requesterSignal)

  )

  # ── Handle message async proc ──────────────────────────────────────
  # Processes a single request message from the request channel.
  # The dispatch loop calls this via asyncSpawn for each received message.
  let handleMsgIdent = ident("handleMsg" & typeDisplayName)
  let msgIdent = ident("msg")
  let loopCtxIdent = ident("loopCtx")

  var handleBody = newStmtList()

  # Handle zero-arg request
  if not zeroArgSig.isNil():
    let handlerIdent0 = ident("handler0")
    handleBody.add(
      quote do:
        if `msgIdent`.requestKind == 0:
          var `handlerIdent0`: `zeroArgProviderName`
          for i in 0 ..< `tvNoArgCtxIdent`.len:
            if `tvNoArgCtxIdent`[i] == `loopCtxIdent`:
              `handlerIdent0` = `tvNoArgHandlerIdent`[i]
              break
          if `handlerIdent0`.isNil():
            `sendReplyIdent`(
              `msgIdent`.responseChan,
              `msgIdent`.requesterSignal,
              err(
                Result[`typeIdent`, string],
                "RequestBroker(" & `typeNameLit` & "): no zero-arg provider registered",
              ),
            )
          else:
            let catchedRes = catch:
              await `handlerIdent0`()
            if catchedRes.isErr():
              `sendReplyIdent`(
                `msgIdent`.responseChan,
                `msgIdent`.requesterSignal,
                err(
                  Result[`typeIdent`, string],
                  "RequestBroker(" & `typeNameLit` & "): provider threw exception: " &
                    catchedRes.error.msg,
                ),
              )
            else:
              let providerRes = catchedRes.get()
              if providerRes.isOk():
                let resultValue = providerRes.get()
                when compiles(resultValue.isNil()):
                  if resultValue.isNil():
                    `sendReplyIdent`(
                      `msgIdent`.responseChan,
                      `msgIdent`.requesterSignal,
                      err(
                        Result[`typeIdent`, string],
                        "RequestBroker(" & `typeNameLit` &
                          "): provider returned nil result",
                      ),
                    )
                    return
              `sendReplyIdent`(
                `msgIdent`.responseChan, `msgIdent`.requesterSignal, providerRes
              )
    )

  # Handle with-args request
  if not argSig.isNil():
    let argNameIdents = collectParamNames(argParams)
    let handlerIdent1 = ident("handler1")
    var providerCall = newCall(handlerIdent1)
    for argName in argNameIdents:
      providerCall.add(newDotExpr(msgIdent, argName))

    handleBody.add(
      quote do:
        if `msgIdent`.requestKind == 1:
          var `handlerIdent1`: `argProviderName`
          for i in 0 ..< `tvWithArgCtxIdent`.len:
            if `tvWithArgCtxIdent`[i] == `loopCtxIdent`:
              `handlerIdent1` = `tvWithArgHandlerIdent`[i]
              break
          if `handlerIdent1`.isNil():
            `sendReplyIdent`(
              `msgIdent`.responseChan,
              `msgIdent`.requesterSignal,
              err(
                Result[`typeIdent`, string],
                "RequestBroker(" & `typeNameLit` &
                  "): no provider registered for input signature",
              ),
            )
          else:
            let catchedRes = catch:
              await `providerCall`
            if catchedRes.isErr():
              `sendReplyIdent`(
                `msgIdent`.responseChan,
                `msgIdent`.requesterSignal,
                err(
                  Result[`typeIdent`, string],
                  "RequestBroker(" & `typeNameLit` & "): provider threw exception: " &
                    catchedRes.error.msg,
                ),
              )
            else:
              let providerRes = catchedRes.get()
              if providerRes.isOk():
                let resultValue = providerRes.get()
                when compiles(resultValue.isNil()):
                  if resultValue.isNil():
                    `sendReplyIdent`(
                      `msgIdent`.responseChan,
                      `msgIdent`.requesterSignal,
                      err(
                        Result[`typeIdent`, string],
                        "RequestBroker(" & `typeNameLit` &
                          "): provider returned nil result",
                      ),
                    )
                    return
              `sendReplyIdent`(
                `msgIdent`.responseChan, `msgIdent`.requesterSignal, providerRes
              )
    )

  result.add(
    quote do:
      proc `handleMsgIdent`(
          `msgIdent`: `requestMsgName`, `loopCtxIdent`: BrokerContext
      ) {.async: (raises: []).} =
        `handleBody`

  )

  # ── Poll fn maker ────────────────────────────────────────────────────
  # Returns a ThreadDispatchPollFn closure that drains the request channel.
  # Return codes: 0 = nothing, 1 = processed (keep), 2 = shutdown (remove).
  # One poll fn is registered per broker type per provider thread.
  let pollFnMakerIdent = ident("makePollFn" & typeDisplayName)
  let deferredFreeReqChanIdent = ident("deferredFreeReqChan" & typeDisplayName)
  result.add(
    quote do:
      proc `deferredFreeReqChanIdent`(
          chanPtr: ptr Channel[`requestMsgName`]
      ) {.async: (raises: []).} =
        # Wait briefly so any cross-thread sender that captured `chanPtr` under
        # the previous lock state has time to complete its send().  After that
        # grace window, close + free.  Channel.close() doesn't synchronise with
        # senders by itself, but the ~50ms delay swallows realistic latencies
        # while keeping the leak bounded.
        let sleepRes = catch:
          await sleepAsync(milliseconds(50))
        if sleepRes.isErr():
          discard
        {.cast(gcsafe).}:
          try:
            chanPtr[].close()
          except Exception:
            discard
        deallocShared(chanPtr)

      proc `pollFnMakerIdent`(
          spawnChan: ptr Channel[`requestMsgName`], loopCtx: BrokerContext
      ): ThreadDispatchPollFn =
        let capturedChan = spawnChan
        let capturedCtx = loopCtx
        return proc(): int {.gcsafe, raises: [].} =
          {.cast(gcsafe).}:
            let tryRes =
              try:
                capturedChan[].tryRecv()
              except Exception:
                return 0
            if not tryRes.dataAvailable:
              return 0
            let msg = tryRes.msg
            if msg.isShutdown:
              # Defer channel teardown so in-flight senders that already passed
              # the bucket lookup can complete safely.  See deferredFreeReqChan.
              asyncSpawn `deferredFreeReqChanIdent`(capturedChan)
              return 2
            asyncSpawn `handleMsgIdent`(msg, capturedCtx)
            return 1

  )

  # ── setProvider (zero-arg) ──────────────────────────────────────────
  if not zeroArgSig.isNil():
    result.add(
      quote do:
        proc setProvider*(
            _: typedesc[`typeIdent`], handler: `zeroArgProviderName`
        ): Result[void, string] =
          `initProcIdent`()
          # Check if already registered on this thread
          let myThreadGen = currentMtThreadGen()
          for i in 0 ..< `tvNoArgCtxIdent`.len:
            if `tvNoArgCtxIdent`[i] == DefaultBrokerContext:
              # Verify entry is still backed by a global bucket.
              # If not, it's stale from a cross-thread clearProvider — remove it.
              var isStale = true
              withLock(`globalLockIdent`):
                for j in 0 ..< `globalBucketCountIdent`:
                  if `globalBucketsIdent`[j].brokerCtx == DefaultBrokerContext and
                      `globalBucketsIdent`[j].threadId == currentMtThreadId() and
                      `globalBucketsIdent`[j].threadGen == myThreadGen:
                    isStale = false
                    break
              if isStale:
                `tvNoArgCtxIdent`.del(i)
                `tvNoArgHandlerIdent`.del(i)
                break # removed stale entry, proceed with registration
              else:
                return err("Zero-arg provider already set")
          # Store in threadvar
          `tvNoArgCtxIdent`.add(DefaultBrokerContext)
          `tvNoArgHandlerIdent`.add(handler)
          var spawnChan: ptr Channel[`requestMsgName`]
          withLock(`globalLockIdent`):
            for i in 0 ..< `globalBucketCountIdent`:
              if `globalBucketsIdent`[i].brokerCtx == DefaultBrokerContext:
                if `globalBucketsIdent`[i].threadId == currentMtThreadId() and
                    `globalBucketsIdent`[i].threadGen == myThreadGen:
                  return ok() # Same thread incarnation, other sig registered first
                else:
                  `tvNoArgCtxIdent`.setLen(`tvNoArgCtxIdent`.len - 1)
                  `tvNoArgHandlerIdent`.setLen(`tvNoArgHandlerIdent`.len - 1)
                  return err(
                    "RequestBroker(" & `typeNameLit` &
                      "): provider already set from another thread"
                  )
            if `globalBucketCountIdent` >= `globalBucketCapIdent`:
              `growProcIdent`()
            spawnChan = cast[ptr Channel[`requestMsgName`]](createShared(
              Channel[`requestMsgName`], 1
            ))
            spawnChan[].open(0)
            let providerSig = getOrInitBrokerSignal()
            let idx = `globalBucketCountIdent`
            `globalBucketsIdent`[idx] = `bucketName`(
              brokerCtx: DefaultBrokerContext,
              requestChan: spawnChan,
              providerSignal: providerSig,
              threadId: currentMtThreadId(),
              threadGen: myThreadGen,
            )
            `globalBucketCountIdent` += 1
          # Register poll fn and start dispatcher outside lock.
          registerBrokerPoller(`pollFnMakerIdent`(spawnChan, DefaultBrokerContext))
          ensureBrokerDispatchStarted()
          return ok()

    )

    result.add(
      quote do:
        proc setProvider*(
            _: typedesc[`typeIdent`],
            brokerCtx: BrokerContext,
            handler: `zeroArgProviderName`,
        ): Result[void, string] =
          if brokerCtx == DefaultBrokerContext:
            return setProvider(`typeIdent`, handler)
          `initProcIdent`()
          let myThreadGen = currentMtThreadGen()
          for i in 0 ..< `tvNoArgCtxIdent`.len:
            if `tvNoArgCtxIdent`[i] == brokerCtx:
              # Verify entry is still backed by a global bucket.
              var isStale = true
              withLock(`globalLockIdent`):
                for j in 0 ..< `globalBucketCountIdent`:
                  if `globalBucketsIdent`[j].brokerCtx == brokerCtx and
                      `globalBucketsIdent`[j].threadId == currentMtThreadId() and
                      `globalBucketsIdent`[j].threadGen == myThreadGen:
                    isStale = false
                    break
              if isStale:
                `tvNoArgCtxIdent`.del(i)
                `tvNoArgHandlerIdent`.del(i)
                break
              else:
                return err(
                  "RequestBroker(" & `typeNameLit` &
                    "): zero-arg provider already set for broker context " & $brokerCtx
                )
          `tvNoArgCtxIdent`.add(brokerCtx)
          `tvNoArgHandlerIdent`.add(handler)
          var spawnChan: ptr Channel[`requestMsgName`]
          withLock(`globalLockIdent`):
            for i in 0 ..< `globalBucketCountIdent`:
              if `globalBucketsIdent`[i].brokerCtx == brokerCtx:
                if `globalBucketsIdent`[i].threadId == currentMtThreadId() and
                    `globalBucketsIdent`[i].threadGen == myThreadGen:
                  return ok()
                else:
                  `tvNoArgCtxIdent`.setLen(`tvNoArgCtxIdent`.len - 1)
                  `tvNoArgHandlerIdent`.setLen(`tvNoArgHandlerIdent`.len - 1)
                  return err(
                    "RequestBroker(" & `typeNameLit` &
                      "): provider already set from another thread for context " &
                      $brokerCtx
                  )
            if `globalBucketCountIdent` >= `globalBucketCapIdent`:
              `growProcIdent`()
            spawnChan = cast[ptr Channel[`requestMsgName`]](createShared(
              Channel[`requestMsgName`], 1
            ))
            spawnChan[].open(0)
            let providerSig = getOrInitBrokerSignal()
            let idx = `globalBucketCountIdent`
            `globalBucketsIdent`[idx] = `bucketName`(
              brokerCtx: brokerCtx,
              requestChan: spawnChan,
              providerSignal: providerSig,
              threadId: currentMtThreadId(),
              threadGen: myThreadGen,
            )
            `globalBucketCountIdent` += 1
          # Register poll fn and start dispatcher outside lock.
          registerBrokerPoller(`pollFnMakerIdent`(spawnChan, brokerCtx))
          ensureBrokerDispatchStarted()
          return ok()

    )

  # ── setProvider (with-args) ─────────────────────────────────────────
  if not argSig.isNil():
    result.add(
      quote do:
        proc setProvider*(
            _: typedesc[`typeIdent`], handler: `argProviderName`
        ): Result[void, string] =
          `initProcIdent`()
          let myThreadGen = currentMtThreadGen()
          for i in 0 ..< `tvWithArgCtxIdent`.len:
            if `tvWithArgCtxIdent`[i] == DefaultBrokerContext:
              # Verify entry is still backed by a global bucket.
              var isStale = true
              withLock(`globalLockIdent`):
                for j in 0 ..< `globalBucketCountIdent`:
                  if `globalBucketsIdent`[j].brokerCtx == DefaultBrokerContext and
                      `globalBucketsIdent`[j].threadId == currentMtThreadId() and
                      `globalBucketsIdent`[j].threadGen == myThreadGen:
                    isStale = false
                    break
              if isStale:
                `tvWithArgCtxIdent`.del(i)
                `tvWithArgHandlerIdent`.del(i)
                break
              else:
                return err("Provider already set")
          `tvWithArgCtxIdent`.add(DefaultBrokerContext)
          `tvWithArgHandlerIdent`.add(handler)
          var spawnChan: ptr Channel[`requestMsgName`]
          withLock(`globalLockIdent`):
            for i in 0 ..< `globalBucketCountIdent`:
              if `globalBucketsIdent`[i].brokerCtx == DefaultBrokerContext:
                if `globalBucketsIdent`[i].threadId == currentMtThreadId() and
                    `globalBucketsIdent`[i].threadGen == myThreadGen:
                  return ok()
                else:
                  `tvWithArgCtxIdent`.setLen(`tvWithArgCtxIdent`.len - 1)
                  `tvWithArgHandlerIdent`.setLen(`tvWithArgHandlerIdent`.len - 1)
                  return err(
                    "RequestBroker(" & `typeNameLit` &
                      "): provider already set from another thread"
                  )
            if `globalBucketCountIdent` >= `globalBucketCapIdent`:
              `growProcIdent`()
            spawnChan = cast[ptr Channel[`requestMsgName`]](createShared(
              Channel[`requestMsgName`], 1
            ))
            spawnChan[].open(0)
            let providerSig = getOrInitBrokerSignal()
            let idx = `globalBucketCountIdent`
            `globalBucketsIdent`[idx] = `bucketName`(
              brokerCtx: DefaultBrokerContext,
              requestChan: spawnChan,
              providerSignal: providerSig,
              threadId: currentMtThreadId(),
              threadGen: myThreadGen,
            )
            `globalBucketCountIdent` += 1
          # Register poll fn and start dispatcher outside lock.
          if not spawnChan.isNil:
            registerBrokerPoller(`pollFnMakerIdent`(spawnChan, DefaultBrokerContext))
            ensureBrokerDispatchStarted()
          return ok()

    )

    result.add(
      quote do:
        proc setProvider*(
            _: typedesc[`typeIdent`],
            brokerCtx: BrokerContext,
            handler: `argProviderName`,
        ): Result[void, string] =
          if brokerCtx == DefaultBrokerContext:
            return setProvider(`typeIdent`, handler)
          `initProcIdent`()
          let myThreadGen = currentMtThreadGen()
          for i in 0 ..< `tvWithArgCtxIdent`.len:
            if `tvWithArgCtxIdent`[i] == brokerCtx:
              # Verify entry is still backed by a global bucket.
              var isStale = true
              withLock(`globalLockIdent`):
                for j in 0 ..< `globalBucketCountIdent`:
                  if `globalBucketsIdent`[j].brokerCtx == brokerCtx and
                      `globalBucketsIdent`[j].threadId == currentMtThreadId() and
                      `globalBucketsIdent`[j].threadGen == myThreadGen:
                    isStale = false
                    break
              if isStale:
                `tvWithArgCtxIdent`.del(i)
                `tvWithArgHandlerIdent`.del(i)
                break
              else:
                return err(
                  "RequestBroker(" & `typeNameLit` &
                    "): provider already set for broker context " & $brokerCtx
                )
          `tvWithArgCtxIdent`.add(brokerCtx)
          `tvWithArgHandlerIdent`.add(handler)
          var spawnChan: ptr Channel[`requestMsgName`]
          withLock(`globalLockIdent`):
            for i in 0 ..< `globalBucketCountIdent`:
              if `globalBucketsIdent`[i].brokerCtx == brokerCtx:
                if `globalBucketsIdent`[i].threadId == currentMtThreadId() and
                    `globalBucketsIdent`[i].threadGen == myThreadGen:
                  return ok()
                else:
                  `tvWithArgCtxIdent`.setLen(`tvWithArgCtxIdent`.len - 1)
                  `tvWithArgHandlerIdent`.setLen(`tvWithArgHandlerIdent`.len - 1)
                  return err(
                    "RequestBroker(" & `typeNameLit` &
                      "): provider already set from another thread for context " &
                      $brokerCtx
                  )
            if `globalBucketCountIdent` >= `globalBucketCapIdent`:
              `growProcIdent`()
            spawnChan = cast[ptr Channel[`requestMsgName`]](createShared(
              Channel[`requestMsgName`], 1
            ))
            spawnChan[].open(0)
            let providerSig = getOrInitBrokerSignal()
            let idx = `globalBucketCountIdent`
            `globalBucketsIdent`[idx] = `bucketName`(
              brokerCtx: brokerCtx,
              requestChan: spawnChan,
              providerSignal: providerSig,
              threadId: currentMtThreadId(),
              threadGen: myThreadGen,
            )
            `globalBucketCountIdent` += 1
          # Register poll fn and start dispatcher outside lock.
          if not spawnChan.isNil:
            registerBrokerPoller(`pollFnMakerIdent`(spawnChan, brokerCtx))
            ensureBrokerDispatchStarted()
          return ok()

    )

  # ── request (zero-arg) ──────────────────────────────────────────────
  if not zeroArgSig.isNil():
    result.add(
      quote do:
        proc request*(
            _: typedesc[`typeIdent`]
        ): Future[Result[`typeIdent`, string]] {.async: (raises: []).} =
          return await request(`typeIdent`, DefaultBrokerContext)

    )
    result.add(
      quote do:
        proc request*(
            _: typedesc[`typeIdent`], brokerCtx: BrokerContext
        ): Future[Result[`typeIdent`, string]] {.async: (raises: []).} =
          `initProcIdent`()
          var reqChan: ptr Channel[`requestMsgName`]
          var providerSignal: ThreadSignalPtr
          var sameThread = false
          let myThreadGen = currentMtThreadGen()

          withLock(`globalLockIdent`):
            for i in 0 ..< `globalBucketCountIdent`:
              if `globalBucketsIdent`[i].brokerCtx == brokerCtx:
                if `globalBucketsIdent`[i].threadId == currentMtThreadId() and
                    `globalBucketsIdent`[i].threadGen == myThreadGen:
                  sameThread = true
                else:
                  reqChan = `globalBucketsIdent`[i].requestChan
                  providerSignal = `globalBucketsIdent`[i].providerSignal
                break

          if sameThread:
            # Same-thread: read handler from threadvar, call directly.
            var provider: `zeroArgProviderName`
            for i in 0 ..< `tvNoArgCtxIdent`.len:
              if `tvNoArgCtxIdent`[i] == brokerCtx:
                provider = `tvNoArgHandlerIdent`[i]
                break
            if provider.isNil():
              return err(
                "RequestBroker(" & `typeNameLit` & "): no zero-arg provider registered"
              )
            let catchedRes = catch:
              await provider()
            if catchedRes.isErr():
              return err(
                "RequestBroker(" & `typeNameLit` & "): provider threw exception: " &
                  catchedRes.error.msg
              )
            let providerRes = catchedRes.get()
            if providerRes.isOk():
              let resultValue = providerRes.get()
              when compiles(resultValue.isNil()):
                if resultValue.isNil():
                  return err(
                    "RequestBroker(" & `typeNameLit` & "): provider returned nil result"
                  )
            return providerRes
          else:
            if reqChan.isNil():
              return err(
                "RequestBroker(" & `typeNameLit` &
                  "): no zero-arg provider registered for broker context " & $brokerCtx
              )
            # Set up per-thread dispatcher for the response channel.
            let mySignal = getOrInitBrokerSignal()
            ensureBrokerDispatchStarted()
            let respChan = cast[ptr Channel[Result[`typeIdent`, string]]](createShared(
              Channel[Result[`typeIdent`, string]], 1
            ))
            respChan[].open(0)
            let responseFut =
              newFuture[Result[`typeIdent`, string]]("request." & `typeNameLit`)
            # Register a one-shot response poller.  When the provider sends its
            # result, the poller completes responseFut and frees respChan.  If
            # the provider never responds (crashed / hung), the poller still
            # gives up and frees once the drop-dead deadline elapses, bounding
            # the leak that previously persisted forever past timeout.
            let capturedRespChan = respChan
            let capturedResponseFut = responseFut
            let respDropDeadDeadline =
              Moment.now() + `timeoutVarIdent` * 5 + chronos.seconds(60)
            let capturedRespDeadline = respDropDeadDeadline
            registerBrokerPoller(
              proc(): int {.gcsafe, raises: [].} =
                {.cast(gcsafe).}:
                  let tryRes =
                    try:
                      capturedRespChan[].tryRecv()
                    except Exception:
                      return 0
                  if not tryRes.dataAvailable:
                    if Moment.now() > capturedRespDeadline:
                      # Provider never responded within the grace window.
                      # Close the channel (further sends raise harmlessly) and
                      # free the memory.  Self-remove the poller.
                      try:
                        capturedRespChan[].close()
                      except Exception:
                        discard
                      deallocShared(capturedRespChan)
                      return 2
                    return 0
                  if not capturedResponseFut.finished:
                    capturedResponseFut.complete(tryRes.msg)
                  deallocShared(capturedRespChan)
                  return 2
            )
            var msg = `requestMsgName`(
              isShutdown: false,
              requestKind: 0,
              responseChan: respChan,
              requesterSignal: mySignal,
            )
            {.cast(gcsafe).}:
              try:
                reqChan[].send(msg)
              except Exception:
                discard
            fireBrokerSignal(providerSignal)
            let completedRes = catch:
              await withTimeout(responseFut, `timeoutVarIdent`)
            if completedRes.isErr():
              # withTimeout itself threw.  Cancel responseFut so the poller
              # skips complete() when the provider eventually responds.
              responseFut.cancelSoon()
              return err(
                "RequestBroker(" & `typeNameLit` & "): recv failed: " &
                  completedRes.error.msg
              )
            if not completedRes.get():
              # Timed out.  Cancel responseFut; the poller stays registered and
              # will free respChan once the provider eventually responds.
              responseFut.cancelSoon()
              return err(
                "RequestBroker(" & `typeNameLit` &
                  "): cross-thread request timed out after " & $`timeoutVarIdent`
              )
            # Success: responseFut completed by the poller, respChan already freed.
            let recvRes = catch:
              responseFut.read()
            if recvRes.isErr():
              return err(
                "RequestBroker(" & `typeNameLit` & "): recv failed: " & recvRes.error.msg
              )
            return recvRes.get()

    )
  else:
    # Stub zero-arg request (no zero-arg signature declared).
    result.add(
      quote do:
        proc request*(
            _: typedesc[`typeIdent`]
        ): Future[Result[`typeIdent`, string]] {.async: (raises: []).} =
          return
            err("RequestBroker(" & `typeNameLit` & "): no zero-arg provider registered")

    )

  # ── blockingRequest (zero-arg) ──────────────────────────────────────
  # Synchronous variant for use in FFI callbacks and non-async contexts.
  # Same-thread path calls the provider directly via blockingAwait.
  # Cross-thread path busy-polls the response channel with sleep(1) until
  # the provider sends its result or the timeout expires.
  if not zeroArgSig.isNil():
    result.add(
      quote do:
        proc blockingRequest*(
            _: typedesc[`typeIdent`]
        ): Result[`typeIdent`, string] {.gcsafe, raises: [].} =
          return blockingRequest(`typeIdent`, DefaultBrokerContext)

    )
    result.add(
      quote do:
        proc blockingRequest*(
            _: typedesc[`typeIdent`], brokerCtx: BrokerContext
        ): Result[`typeIdent`, string] {.gcsafe, raises: [].} =
          `initProcIdent`()
          var reqChan: ptr Channel[`requestMsgName`]
          var providerSignal: ThreadSignalPtr
          var sameThread = false
          let myThreadGen = currentMtThreadGen()

          withLock(`globalLockIdent`):
            for i in 0 ..< `globalBucketCountIdent`:
              if `globalBucketsIdent`[i].brokerCtx == brokerCtx:
                if `globalBucketsIdent`[i].threadId == currentMtThreadId() and
                    `globalBucketsIdent`[i].threadGen == myThreadGen:
                  sameThread = true
                else:
                  reqChan = `globalBucketsIdent`[i].requestChan
                  providerSignal = `globalBucketsIdent`[i].providerSignal
                break

          if sameThread:
            var provider: `zeroArgProviderName`
            for i in 0 ..< `tvNoArgCtxIdent`.len:
              if `tvNoArgCtxIdent`[i] == brokerCtx:
                provider = `tvNoArgHandlerIdent`[i]
                break
            if provider.isNil():
              return err(
                "RequestBroker(" & `typeNameLit` & "): no zero-arg provider registered"
              )
            let catchedRes = catch:
              blockingAwait(provider())
            if catchedRes.isErr():
              return err(
                "RequestBroker(" & `typeNameLit` & "): provider threw exception: " &
                  catchedRes.error.msg
              )
            let providerRes = catchedRes.get()
            if providerRes.isOk():
              let resultValue = providerRes.get()
              when compiles(resultValue.isNil()):
                if resultValue.isNil():
                  return err(
                    "RequestBroker(" & `typeNameLit` & "): provider returned nil result"
                  )
            return providerRes
          else:
            if reqChan.isNil():
              return err(
                "RequestBroker(" & `typeNameLit` &
                  "): no zero-arg provider registered for broker context " & $brokerCtx
              )
            let respChan = cast[ptr Channel[Result[`typeIdent`, string]]](createShared(
              Channel[Result[`typeIdent`, string]], 1
            ))
            respChan[].open(0)
            var msg = `requestMsgName`(
              isShutdown: false,
              requestKind: 0,
              responseChan: respChan,
              requesterSignal: nil, # no async loop on this thread
            )
            {.cast(gcsafe).}:
              try:
                reqChan[].send(msg)
              except Exception:
                discard
            fireBrokerSignal(providerSignal)
            let deadline = Moment.now() + `timeoutVarIdent`
            var gotResponse = false
            var response: Result[`typeIdent`, string]
            while Moment.now() < deadline:
              let tryRes =
                try:
                  {.cast(gcsafe).}:
                    respChan[].tryRecv()
                except Exception:
                  (dataAvailable: false, msg: response)
              if tryRes.dataAvailable:
                response = tryRes.msg
                gotResponse = true
                break
              sleep(1)
            if not gotResponse:
              # Intentional leak on timeout: provider may still hold respChan and
              # will send its result eventually.  Channel[T] costs only memory
              # (mutex + condvar), no OS file descriptors.
              return err(
                "RequestBroker(" & `typeNameLit` &
                  "): cross-thread request timed out after " & $`timeoutVarIdent`
              )
            deallocShared(respChan)
            return response

    )
  else:
    result.add(
      quote do:
        proc blockingRequest*(
            _: typedesc[`typeIdent`]
        ): Result[`typeIdent`, string] {.gcsafe, raises: [].} =
          return
            err("RequestBroker(" & `typeNameLit` & "): no zero-arg provider registered")

    )

  # ── request (with-args) ─────────────────────────────────────────────
  if not argSig.isNil():
    let requestParamDefs = cloneParams(argParams)
    let argNameIdents = collectParamNames(requestParamDefs)

    # Non-keyed variant: forward to default context.
    var formalParams = newTree(nnkFormalParams)
    formalParams.add(copyNimTree(returnType))
    formalParams.add(
      newTree(
        nnkIdentDefs,
        ident("_"),
        newTree(nnkBracketExpr, ident("typedesc"), copyNimTree(typeIdent)),
        newEmptyNode(),
      )
    )
    for paramDef in requestParamDefs:
      formalParams.add(paramDef)

    var forwardCall = newCall(ident("request"))
    forwardCall.add(copyNimTree(typeIdent))
    forwardCall.add(ident("DefaultBrokerContext"))
    for argName in argNameIdents:
      forwardCall.add(argName)

    let requestPragmas = quote:
      {.async: (raises: []).}

    let forwardBody = newStmtList(
      quote do:
        return await `forwardCall`
    )

    result.add(
      newTree(
        nnkProcDef,
        postfix(ident("request"), "*"),
        newEmptyNode(),
        newEmptyNode(),
        formalParams,
        requestPragmas,
        newEmptyNode(),
        forwardBody,
      )
    )

    # Keyed variant with same-thread optimization.
    let requestParamDefsKeyed = cloneParams(argParams)
    let argNameIdentsKeyed = collectParamNames(requestParamDefsKeyed)
    var formalParamsKeyed = newTree(nnkFormalParams)
    formalParamsKeyed.add(copyNimTree(returnType))
    formalParamsKeyed.add(
      newTree(
        nnkIdentDefs,
        ident("_"),
        newTree(nnkBracketExpr, ident("typedesc"), copyNimTree(typeIdent)),
        newEmptyNode(),
      )
    )
    formalParamsKeyed.add(
      newTree(nnkIdentDefs, ident("brokerCtx"), ident("BrokerContext"), newEmptyNode())
    )
    for paramDef in requestParamDefsKeyed:
      formalParamsKeyed.add(paramDef)

    # Build the provider call for same-thread path.
    let providerSymKeyed = genSym(nskVar, "provider")
    var providerCallKeyed = newCall(providerSymKeyed)
    for argName in argNameIdentsKeyed:
      providerCallKeyed.add(argName)

    # Shared idents for cross-thread path.
    let respChanIdent = ident("respChan")
    let reqChanIdent = ident("reqChan")
    let sameThreadIdent = ident("sameThread")
    let providerSignalIdent = ident("providerSignal")
    let mySignalIdent = ident("mySignal")

    # Build request message construction for cross-thread path.
    var msgConstruction = newTree(nnkObjConstr, requestMsgName)
    msgConstruction.add(newTree(nnkExprColonExpr, ident("isShutdown"), newLit(false)))
    msgConstruction.add(newTree(nnkExprColonExpr, ident("requestKind"), newLit(1)))
    for argName in argNameIdentsKeyed:
      msgConstruction.add(newTree(nnkExprColonExpr, argName, argName))
    msgConstruction.add(newTree(nnkExprColonExpr, ident("responseChan"), respChanIdent))
    msgConstruction.add(
      newTree(nnkExprColonExpr, ident("requesterSignal"), mySignalIdent)
    )

    var requestBodyKeyed = newStmtList()
    requestBodyKeyed.add(
      quote do:
        `initProcIdent`()
        var `reqChanIdent`: ptr Channel[`requestMsgName`]
        var `providerSignalIdent`: ThreadSignalPtr
        var `sameThreadIdent` = false
        let myThreadGen = currentMtThreadGen()

        withLock(`globalLockIdent`):
          for i in 0 ..< `globalBucketCountIdent`:
            if `globalBucketsIdent`[i].brokerCtx == brokerCtx:
              if `globalBucketsIdent`[i].threadId == currentMtThreadId() and
                  `globalBucketsIdent`[i].threadGen == myThreadGen:
                `sameThreadIdent` = true
              else:
                `reqChanIdent` = `globalBucketsIdent`[i].requestChan
                `providerSignalIdent` = `globalBucketsIdent`[i].providerSignal
              break

        if `sameThreadIdent`:
          # Same-thread: read handler from threadvar, call directly.
          var `providerSymKeyed`: `argProviderName`
          for i in 0 ..< `tvWithArgCtxIdent`.len:
            if `tvWithArgCtxIdent`[i] == brokerCtx:
              `providerSymKeyed` = `tvWithArgHandlerIdent`[i]
              break
          if `providerSymKeyed`.isNil():
            return err(
              "RequestBroker(" & `typeNameLit` &
                "): no provider registered for input signature"
            )
          let catchedRes = catch:
            await `providerCallKeyed`
          if catchedRes.isErr():
            return err(
              "RequestBroker(" & `typeNameLit` & "): provider threw exception: " &
                catchedRes.error.msg
            )
          let providerRes = catchedRes.get()
          if providerRes.isOk():
            let resultValue = providerRes.get()
            when compiles(resultValue.isNil()):
              if resultValue.isNil():
                return err(
                  "RequestBroker(" & `typeNameLit` & "): provider returned nil result"
                )
          return providerRes
        else:
          if `reqChanIdent`.isNil():
            return err(
              "RequestBroker(" & `typeNameLit` &
                "): no provider registered for broker context " & $brokerCtx
            )
          let `mySignalIdent` = getOrInitBrokerSignal()
          ensureBrokerDispatchStarted()
          let `respChanIdent` = cast[ptr Channel[Result[`typeIdent`, string]]](createShared(
            Channel[Result[`typeIdent`, string]], 1
          ))
          `respChanIdent`[].open(0)
          let responseFut =
            newFuture[Result[`typeIdent`, string]]("request." & `typeNameLit`)
          let capturedRespChan = `respChanIdent`
          let capturedResponseFut = responseFut
          let respDropDeadDeadline =
            Moment.now() + `timeoutVarIdent` * 5 + chronos.seconds(60)
          let capturedRespDeadline = respDropDeadDeadline
          registerBrokerPoller(
            proc(): int {.gcsafe, raises: [].} =
              {.cast(gcsafe).}:
                let tryRes =
                  try:
                    capturedRespChan[].tryRecv()
                  except Exception:
                    return 0
                if not tryRes.dataAvailable:
                  if Moment.now() > capturedRespDeadline:
                    try:
                      capturedRespChan[].close()
                    except Exception:
                      discard
                    deallocShared(capturedRespChan)
                    return 2
                  return 0
                if not capturedResponseFut.finished:
                  capturedResponseFut.complete(tryRes.msg)
                deallocShared(capturedRespChan)
                return 2
          )
          var msg = `msgConstruction`
          {.cast(gcsafe).}:
            try:
              `reqChanIdent`[].send(msg)
            except Exception:
              discard
          fireBrokerSignal(`providerSignalIdent`)
          let completedRes = catch:
            await withTimeout(responseFut, `timeoutVarIdent`)
          if completedRes.isErr():
            responseFut.cancelSoon()
            return err(
              "RequestBroker(" & `typeNameLit` & "): recv failed: " &
                completedRes.error.msg
            )
          if not completedRes.get():
            responseFut.cancelSoon()
            return err(
              "RequestBroker(" & `typeNameLit` &
                "): cross-thread request timed out after " & $`timeoutVarIdent`
            )
          # Success: responseFut completed by the poller, respChan already freed.
          let recvRes = catch:
            responseFut.read()
          if recvRes.isErr():
            return err(
              "RequestBroker(" & `typeNameLit` & "): recv failed: " & recvRes.error.msg
            )
          return recvRes.get()
    )

    result.add(
      newTree(
        nnkProcDef,
        postfix(ident("request"), "*"),
        newEmptyNode(),
        newEmptyNode(),
        formalParamsKeyed,
        requestPragmas,
        newEmptyNode(),
        requestBodyKeyed,
      )
    )

  # ── blockingRequest (with-args) ─────────────────────────────────────
  # Synchronous variant for use in FFI callbacks and non-async contexts.
  if not argSig.isNil():
    let brParamDefs = cloneParams(argParams)
    let brArgNameIdents = collectParamNames(brParamDefs)
    let brPragmas = quote:
      {.gcsafe, raises: [].}

    # Non-keyed forward proc.
    var brFormalParams = newTree(nnkFormalParams)
    brFormalParams.add(
      newTree(nnkBracketExpr, ident("Result"), copyNimTree(typeIdent), ident("string"))
    )
    brFormalParams.add(
      newTree(
        nnkIdentDefs,
        ident("_"),
        newTree(nnkBracketExpr, ident("typedesc"), copyNimTree(typeIdent)),
        newEmptyNode(),
      )
    )
    for paramDef in brParamDefs:
      brFormalParams.add(paramDef)

    var brForwardCall = newCall(ident("blockingRequest"))
    brForwardCall.add(copyNimTree(typeIdent))
    brForwardCall.add(ident("DefaultBrokerContext"))
    for argName in brArgNameIdents:
      brForwardCall.add(argName)

    result.add(
      newTree(
        nnkProcDef,
        postfix(ident("blockingRequest"), "*"),
        newEmptyNode(),
        newEmptyNode(),
        brFormalParams,
        brPragmas,
        newEmptyNode(),
        newStmtList(newTree(nnkReturnStmt, brForwardCall)),
      )
    )

    # Keyed blockingRequest with same-thread optimization.
    let brParamDefsKeyed = cloneParams(argParams)
    let brArgNameIdentsKeyed = collectParamNames(brParamDefsKeyed)
    var brFormalParamsKeyed = newTree(nnkFormalParams)
    brFormalParamsKeyed.add(
      newTree(nnkBracketExpr, ident("Result"), copyNimTree(typeIdent), ident("string"))
    )
    brFormalParamsKeyed.add(
      newTree(
        nnkIdentDefs,
        ident("_"),
        newTree(nnkBracketExpr, ident("typedesc"), copyNimTree(typeIdent)),
        newEmptyNode(),
      )
    )
    brFormalParamsKeyed.add(
      newTree(nnkIdentDefs, ident("brokerCtx"), ident("BrokerContext"), newEmptyNode())
    )
    for paramDef in brParamDefsKeyed:
      brFormalParamsKeyed.add(paramDef)

    let brProviderSymKeyed = genSym(nskVar, "provider")
    var brProviderCallKeyed = newCall(brProviderSymKeyed)
    for argName in brArgNameIdentsKeyed:
      brProviderCallKeyed.add(argName)

    let brRespChanIdent = ident("respChan")
    let brReqChanIdent = ident("reqChan")
    let brSameThreadIdent = ident("sameThread")
    let brProviderSignalIdent = ident("providerSignal")

    var brMsgConstruction = newTree(nnkObjConstr, requestMsgName)
    brMsgConstruction.add(newTree(nnkExprColonExpr, ident("isShutdown"), newLit(false)))
    brMsgConstruction.add(newTree(nnkExprColonExpr, ident("requestKind"), newLit(1)))
    for argName in brArgNameIdentsKeyed:
      brMsgConstruction.add(newTree(nnkExprColonExpr, argName, argName))
    brMsgConstruction.add(
      newTree(nnkExprColonExpr, ident("responseChan"), brRespChanIdent)
    )
    brMsgConstruction.add(
      newTree(
        nnkExprColonExpr,
        ident("requesterSignal"),
        newNilLit(), # no async loop on this thread
      )
    )

    var brRequestBodyKeyed = newStmtList()
    brRequestBodyKeyed.add(
      quote do:
        `initProcIdent`()
        var `brReqChanIdent`: ptr Channel[`requestMsgName`]
        var `brProviderSignalIdent`: ThreadSignalPtr
        var `brSameThreadIdent` = false
        let myThreadGen = currentMtThreadGen()

        withLock(`globalLockIdent`):
          for i in 0 ..< `globalBucketCountIdent`:
            if `globalBucketsIdent`[i].brokerCtx == brokerCtx:
              if `globalBucketsIdent`[i].threadId == currentMtThreadId() and
                  `globalBucketsIdent`[i].threadGen == myThreadGen:
                `brSameThreadIdent` = true
              else:
                `brReqChanIdent` = `globalBucketsIdent`[i].requestChan
                `brProviderSignalIdent` = `globalBucketsIdent`[i].providerSignal
              break

        if `brSameThreadIdent`:
          var `brProviderSymKeyed`: `argProviderName`
          for i in 0 ..< `tvWithArgCtxIdent`.len:
            if `tvWithArgCtxIdent`[i] == brokerCtx:
              `brProviderSymKeyed` = `tvWithArgHandlerIdent`[i]
              break
          if `brProviderSymKeyed`.isNil():
            return err(
              "RequestBroker(" & `typeNameLit` &
                "): no provider registered for input signature"
            )
          let catchedRes = catch:
            blockingAwait(`brProviderCallKeyed`)
          if catchedRes.isErr():
            return err(
              "RequestBroker(" & `typeNameLit` & "): provider threw exception: " &
                catchedRes.error.msg
            )
          let providerRes = catchedRes.get()
          if providerRes.isOk():
            let resultValue = providerRes.get()
            when compiles(resultValue.isNil()):
              if resultValue.isNil():
                return err(
                  "RequestBroker(" & `typeNameLit` & "): provider returned nil result"
                )
          return providerRes
        else:
          if `brReqChanIdent`.isNil():
            return err(
              "RequestBroker(" & `typeNameLit` &
                "): no provider registered for broker context " & $brokerCtx
            )
          let `brRespChanIdent` = cast[ptr Channel[Result[`typeIdent`, string]]](createShared(
            Channel[Result[`typeIdent`, string]], 1
          ))
          `brRespChanIdent`[].open(0)
          var msg = `brMsgConstruction`
          {.cast(gcsafe).}:
            try:
              `brReqChanIdent`[].send(msg)
            except Exception:
              discard
          fireBrokerSignal(`brProviderSignalIdent`)
          let deadline = Moment.now() + `timeoutVarIdent`
          var gotResponse = false
          var response: Result[`typeIdent`, string]
          while Moment.now() < deadline:
            let tryRes =
              try:
                {.cast(gcsafe).}:
                  `brRespChanIdent`[].tryRecv()
              except Exception:
                (dataAvailable: false, msg: response)
            if tryRes.dataAvailable:
              response = tryRes.msg
              gotResponse = true
              break
            sleep(1)
          if not gotResponse:
            # Intentional leak on timeout — same rationale as async request().
            # Channel[T] costs only memory (mutex + condvar), no OS file descriptors.
            return err(
              "RequestBroker(" & `typeNameLit` &
                "): cross-thread request timed out after " & $`timeoutVarIdent`
            )
          deallocShared(`brRespChanIdent`)
          return response
    )

    result.add(
      newTree(
        nnkProcDef,
        postfix(ident("blockingRequest"), "*"),
        newEmptyNode(),
        newEmptyNode(),
        brFormalParamsKeyed,
        brPragmas,
        newEmptyNode(),
        brRequestBodyKeyed,
      )
    )

  # ── clearProvider ───────────────────────────────────────────────────
  let brokerCtxParam = ident("brokerCtx")
  var clearBody = newStmtList()

  # Build threadvar cleanup statements.
  var tvCleanup = newStmtList()
  if not zeroArgSig.isNil():
    tvCleanup.add(
      quote do:
        for i in countdown(`tvNoArgCtxIdent`.len - 1, 0):
          if `tvNoArgCtxIdent`[i] == `brokerCtxParam`:
            `tvNoArgCtxIdent`.del(i)
            `tvNoArgHandlerIdent`.del(i)
            break
    )
  if not argSig.isNil():
    tvCleanup.add(
      quote do:
        for i in countdown(`tvWithArgCtxIdent`.len - 1, 0):
          if `tvWithArgCtxIdent`[i] == `brokerCtxParam`:
            `tvWithArgCtxIdent`.del(i)
            `tvWithArgHandlerIdent`.del(i)
            break
    )

  clearBody.add(
    quote do:
      `initProcIdent`()
      var reqChan: ptr Channel[`requestMsgName`]
      var providerSignal: ThreadSignalPtr
      var isProviderThread = false
      let myThreadGen = currentMtThreadGen()
      withLock(`globalLockIdent`):
        var foundIdx = -1
        for i in 0 ..< `globalBucketCountIdent`:
          if `globalBucketsIdent`[i].brokerCtx == `brokerCtxParam`:
            reqChan = `globalBucketsIdent`[i].requestChan
            providerSignal = `globalBucketsIdent`[i].providerSignal
            isProviderThread = (
              `globalBucketsIdent`[i].threadId == currentMtThreadId() and
              `globalBucketsIdent`[i].threadGen == myThreadGen
            )
            foundIdx = i
            break
        if foundIdx >= 0:
          # Remove bucket by shifting.
          for i in foundIdx ..< `globalBucketCountIdent` - 1:
            `globalBucketsIdent`[i] = `globalBucketsIdent`[i + 1]
          `globalBucketCountIdent` -= 1
      # Only clean threadvar entries if called from the provider thread.
      # If called from another thread, the poll fn will self-remove when it
      # receives the shutdown message.
      if isProviderThread:
        `tvCleanup`
      elif not reqChan.isNil():
        trace "clearProvider called from non-provider thread; " &
          "threadvar entries on provider thread are stale but harmless " &
          "(next setProvider will detect and clean them)", brokerType = `typeNameLit`
      if not reqChan.isNil():
        # Send shutdown; the poll fn returns 2 (removes itself) on isShutdown.
        var shutdownMsg = `requestMsgName`(isShutdown: true, requesterSignal: nil)
        {.cast(gcsafe).}:
          try:
            reqChan[].send(shutdownMsg)
          except Exception:
            discard
        fireBrokerSignal(providerSignal)
  )

  var formalParamsClear = newTree(nnkFormalParams)
  formalParamsClear.add(newEmptyNode())
  formalParamsClear.add(
    newTree(
      nnkIdentDefs,
      ident("_"),
      newTree(nnkBracketExpr, ident("typedesc"), copyNimTree(typeIdent)),
      newEmptyNode(),
    )
  )
  formalParamsClear.add(
    newTree(nnkIdentDefs, brokerCtxParam, ident("BrokerContext"), newEmptyNode())
  )
  result.add(
    newTree(
      nnkProcDef,
      postfix(ident("clearProvider"), "*"),
      newEmptyNode(),
      newEmptyNode(),
      formalParamsClear,
      newEmptyNode(),
      newEmptyNode(),
      clearBody,
    )
  )

  result.add(
    quote do:
      proc clearProvider*(_: typedesc[`typeIdent`]) =
        clearProvider(`typeIdent`, DefaultBrokerContext)

  )

  when defined(brokerDebug):
    echo result.repr

  return result

{.pop.}
