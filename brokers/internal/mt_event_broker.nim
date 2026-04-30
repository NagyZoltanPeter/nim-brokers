## Multi-Thread EventBroker
## -----------------------
## Generates a multi-thread capable EventBroker where listeners can be registered
## on any thread and events can be emitted from any thread. Events are delivered
## to all registered listeners across all threads (broadcast fan-out).
##
## Same-thread listeners bypass channels and are dispatched directly via asyncSpawn.
## Cross-thread delivery uses Channel[T] + per-thread shared signal (0 fds).
##
## The broker does NOT own or spawn threads — that is the user's responsibility.
## The global registry uses `createShared` / raw pointers so it is safe under
## both `--mm:orc` and `--mm:refc`.
##
## Listener closures are stored in threadvars (GC-managed, per-thread) rather
## than in the shared bucket, avoiding the need to cast closures to raw pointers.
##
## `dropListener` must be called from the thread that registered the listener.
## `dropAllListeners` can be called from any thread — it sends emkClearListeners
## to all listener threads for the context.

{.push raises: [].}

import std/[macros, locks, tables]
import chronos, chronicles
import results
import ./helper/broker_utils, ../broker_context, ./mt_broker_common

export results, chronos, broker_context, chronicles, mt_broker_common

# ---------------------------------------------------------------------------
# Macro code generator
# ---------------------------------------------------------------------------

proc generateMtEventBroker*(body: NimNode): NimNode =
  when defined(brokerDebug):
    echo body.treeRepr
    echo "EventBroker mode: mt"

  let parsed = parseSingleTypeDef(body, "EventBroker", collectFieldInfo = true)
  let typeIdent = parsed.typeIdent
  let objectDef = parsed.objectDef
  let fieldNames = parsed.fieldNames
  let fieldTypes = parsed.fieldTypes
  let hasInlineFields = parsed.hasInlineFields

  let exportedTypeIdent = postfix(copyNimTree(typeIdent), "*")
  let typeDisplayName = sanitizeIdentName(typeIdent)
  let typeNameLit = newLit(typeDisplayName)

  # ── Identifier setup ──────────────────────────────────────────────────
  let handlerProcIdent = ident(typeDisplayName & "ListenerProc")
  let listenerHandleIdent = ident(typeDisplayName & "Listener")
  let exportedHandlerProcIdent = postfix(copyNimTree(handlerProcIdent), "*")
  let exportedListenerHandleIdent = postfix(copyNimTree(listenerHandleIdent), "*")

  let eventMsgKindName = ident(typeDisplayName & "MtEventMsgKind")
  let eventMsgName = ident(typeDisplayName & "MtEventMsg")
  let bucketName = ident(typeDisplayName & "MtEventBucket")

  let globalBucketsIdent = ident("g" & typeDisplayName & "MtBuckets")
  let globalBucketCountIdent = ident("g" & typeDisplayName & "MtBucketCount")
  let globalBucketCapIdent = ident("g" & typeDisplayName & "MtBucketCap")
  let globalLockIdent = ident("g" & typeDisplayName & "MtLock")
  let globalInitIdent = ident("g" & typeDisplayName & "MtInit")

  let initProcIdent = ident("ensureInit" & typeDisplayName & "MtBroker")
  let growProcIdent = ident("grow" & typeDisplayName & "MtBuckets")
  let listenerTaskIdent = ident("notify" & typeDisplayName & "Listener")
  let handleEventMsgIdent = ident("handleEventMsg" & typeDisplayName)
  let pollFnMakerIdent = ident("makePollFn" & typeDisplayName)
  let clearListenersIdent = ident("clearListeners" & typeDisplayName)

  let tvListenerCtxIdent = ident("g" & typeDisplayName & "TvListenerCtxs")
  let tvListenerHandlersIdent = ident("g" & typeDisplayName & "TvListenerHandlers")
  let tvNextIdsIdent = ident("g" & typeDisplayName & "TvNextIds")
  let tvListenerFutsIdent = ident("g" & typeDisplayName & "TvListenerFuts")
  let tvShutdownFutsIdent = ident("g" & typeDisplayName & "TvShutdownFuts")

  let listenImplIdent = ident("listen" & typeDisplayName & "MtImpl")
  let emitImplIdent = ident("emit" & typeDisplayName & "MtImpl")
  let dropListenerImplIdent = ident("drop" & typeDisplayName & "MtListenerImpl")
  let dropAllListenersImplIdent = ident("dropAll" & typeDisplayName & "MtListenersImpl")
  let shutdownProcessLoopsForCtxIdent =
    ident("shutdownProcessLoopsForCtx" & typeDisplayName)

  result = newStmtList()

  # ── Type section ──────────────────────────────────────────────────────
  result.add(
    quote do:
      type
        `exportedTypeIdent` = `objectDef`
        `exportedListenerHandleIdent` = object
          id*: uint64
          threadId*: pointer
            ## Thread that registered this listener (for validation on drop).

        `exportedHandlerProcIdent` =
          proc(event: `typeIdent`): Future[void] {.async: (raises: []), gcsafe.}

        `eventMsgKindName` {.pure.} = enum
          emkEvent ## Normal event delivery
          emkClearListeners ## Clear threadvar handlers, keep poll fn alive
          emkShutdown ## Exit poll fn (no drain — in-flight futures run naturally)

        `eventMsgName` = object
          kind: `eventMsgKindName`
          event: `typeIdent`

        `bucketName` = object
          brokerCtx: BrokerContext
          eventChan: ptr Channel[`eventMsgName`]
          listenerSignal: ThreadSignalPtr
          threadId: pointer
          threadGen: uint64 ## Disambiguates reused threadvar addresses
          active: bool
          hasListeners: bool

  )

  # ── Global shared state ───────────────────────────────────────────────
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

  # ── Init helper (thread-safe via atomic CAS) ───────────────────────────
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

  # ── Grow helper ───────────────────────────────────────────────────────
  result.add(
    quote do:
      proc `growProcIdent`() =
        ## Must be called under lock.
        let newCap = `globalBucketCapIdent` * 2
        let newBuf =
          cast[ptr UncheckedArray[`bucketName`]](createShared(`bucketName`, newCap))
        for i in 0 ..< `globalBucketCountIdent`:
          newBuf[i] = `globalBucketsIdent`[i]
        # Intentional leak: see equivalent comment in mt_request_broker.nim grow.
        `globalBucketsIdent` = newBuf
        `globalBucketCapIdent` = newCap

  )

  # ── Threadvar listener storage ────────────────────────────────────────
  # Parallel seqs: contexts, handler tables, next-ID counters.
  # tvListenerFutsIdent: in-flight listener callback futures (for shutdown drain).
  # tvShutdownFutsIdent: per-bucket shutdown futures (completed by poll fn on emkShutdown).
  result.add(
    quote do:
      var `tvListenerCtxIdent` {.threadvar.}: seq[BrokerContext]
      var `tvListenerHandlersIdent` {.threadvar.}:
        seq[Table[uint64, `handlerProcIdent`]]
      var `tvNextIdsIdent` {.threadvar.}: seq[uint64]
      var `tvListenerFutsIdent` {.threadvar.}: seq[(BrokerContext, Future[void])]
      var `tvShutdownFutsIdent` {.threadvar.}: seq[(BrokerContext, Future[void])]
  )

  # ── Listener notify wrapper ───────────────────────────────────────────
  result.add(
    quote do:
      proc `listenerTaskIdent`(
          callback: `handlerProcIdent`, event: `typeIdent`
      ): Future[void] {.async: (raises: []).} =
        if callback.isNil():
          return
        try:
          await callback(event)
        except CatchableError:
          error "Failed to execute event listener",
            eventType = `typeNameLit`, error = getCurrentExceptionMsg()

  )

  # ── Clear listeners helper ────────────────────────────────────────────
  # Removes the handler table entry for the given context from all threadvars.
  # Safe to call from within {.cast(gcsafe).} because it only touches threadvars.
  result.add(
    quote do:
      proc `clearListenersIdent`(loopCtx: BrokerContext) {.gcsafe, raises: [].} =
        {.cast(gcsafe).}:
          for i in 0 ..< `tvListenerCtxIdent`.len:
            if `tvListenerCtxIdent`[i] == loopCtx:
              `tvListenerHandlersIdent`[i].clear()
              `tvListenerCtxIdent`.del(i)
              `tvListenerHandlersIdent`.del(i)
              `tvNextIdsIdent`.del(i)
              break

  )

  # ── Handle event message async proc ──────────────────────────────────
  # Dispatches a single emkEvent to all local listeners.
  # Tracks spawned futures in tvListenerFutsIdent for clean shutdown.
  result.add(
    quote do:
      proc `handleEventMsgIdent`(
          event: `typeIdent`, loopCtx: BrokerContext
      ) {.async: (raises: []).} =
        # Prune completed in-flight futures for this context.
        var i = 0
        while i < `tvListenerFutsIdent`.len:
          if `tvListenerFutsIdent`[i][0] == loopCtx and
              `tvListenerFutsIdent`[i][1].finished():
            `tvListenerFutsIdent`.del(i)
          else:
            inc i

        # Dispatch to all local listeners for this context.
        var idx = -1
        for j in 0 ..< `tvListenerCtxIdent`.len:
          if `tvListenerCtxIdent`[j] == loopCtx:
            idx = j
            break
        if idx >= 0:
          var callbacks: seq[`handlerProcIdent`] = @[]
          for cb in `tvListenerHandlersIdent`[idx].values:
            callbacks.add(cb)
          for cb in callbacks:
            let fut: Future[void] = `listenerTaskIdent`(cb, event)
            `tvListenerFutsIdent`.add((loopCtx, fut))
            asyncSpawn fut

  )

  # ── Poll fn maker ─────────────────────────────────────────────────────
  # Returns a ThreadDispatchPollFn closure that drains the event channel.
  # Return codes: 0 = nothing, 1 = processed (keep), 2 = shutdown (remove).
  result.add(
    quote do:
      proc `pollFnMakerIdent`(
          eventChan: ptr Channel[`eventMsgName`],
          loopCtx: BrokerContext,
          shutdownFut: Future[void],
      ): ThreadDispatchPollFn =
        let capturedChan = eventChan
        let capturedCtx = loopCtx
        let capturedShutdownFut = shutdownFut
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
            case msg.kind
            of `eventMsgKindName`.emkShutdown:
              `clearListenersIdent`(capturedCtx)
              if not capturedShutdownFut.finished:
                capturedShutdownFut.complete()
              return 2
            of `eventMsgKindName`.emkClearListeners:
              `clearListenersIdent`(capturedCtx)
              return 1
            of `eventMsgKindName`.emkEvent:
              asyncSpawn `handleEventMsgIdent`(msg.event, capturedCtx)
              return 1

  )

  # ── listen impl ──────────────────────────────────────────────────────
  result.add(
    quote do:
      proc `listenImplIdent`(
          brokerCtx: BrokerContext, handler: `handlerProcIdent`
      ): Result[`listenerHandleIdent`, string] =
        if handler.isNil():
          return err("Must provide a non-nil event handler")
        `initProcIdent`()

        # Find or create threadvar entry for this context
        var tvIdx = -1
        for i in 0 ..< `tvListenerCtxIdent`.len:
          if `tvListenerCtxIdent`[i] == brokerCtx:
            tvIdx = i
            break
        if tvIdx < 0:
          `tvListenerCtxIdent`.add(brokerCtx)
          `tvListenerHandlersIdent`.add(initTable[uint64, `handlerProcIdent`]())
          `tvNextIdsIdent`.add(1'u64)
          tvIdx = `tvListenerCtxIdent`.len - 1

        # Allocate listener ID
        if `tvNextIdsIdent`[tvIdx] == high(uint64):
          return err("Cannot add more listeners: ID space exhausted")
        let newId = `tvNextIdsIdent`[tvIdx]
        `tvNextIdsIdent`[tvIdx] += 1
        `tvListenerHandlersIdent`[tvIdx][newId] = handler

        # Ensure a bucket + channel exists for (brokerCtx, this thread).
        let myThreadId = currentMtThreadId()
        let myThreadGen = currentMtThreadGen()
        var bucketExists = false
        var spawnChan: ptr Channel[`eventMsgName`]
        withLock(`globalLockIdent`):
          for i in 0 ..< `globalBucketCountIdent`:
            if `globalBucketsIdent`[i].brokerCtx == brokerCtx and
                `globalBucketsIdent`[i].threadId == myThreadId and
                `globalBucketsIdent`[i].threadGen == myThreadGen:
              `globalBucketsIdent`[i].hasListeners = true
              bucketExists = true
              break
          if not bucketExists:
            if `globalBucketCountIdent` >= `globalBucketCapIdent`:
              `growProcIdent`()
            let chan = cast[ptr Channel[`eventMsgName`]](createShared(
              Channel[`eventMsgName`], 1
            ))
            chan[].open(0)
            let listenerSig = getOrInitBrokerSignal()
            let idx = `globalBucketCountIdent`
            `globalBucketsIdent`[idx] = `bucketName`(
              brokerCtx: brokerCtx,
              eventChan: chan,
              listenerSignal: listenerSig,
              threadId: myThreadId,
              threadGen: myThreadGen,
              active: true,
              hasListeners: true,
            )
            `globalBucketCountIdent` += 1
            spawnChan = chan
        # Register poll fn and dispatcher outside lock.
        if not bucketExists and not spawnChan.isNil:
          let shutdownFut =
            newFuture[void]("eventBroker." & `typeNameLit` & ".shutdown")
          `tvShutdownFutsIdent`.add((brokerCtx, shutdownFut))
          registerBrokerPoller(`pollFnMakerIdent`(spawnChan, brokerCtx, shutdownFut))
          ensureBrokerDispatchStarted()

        return ok(`listenerHandleIdent`(id: newId, threadId: myThreadId))

  )

  # ── Public listen ─────────────────────────────────────────────────────
  result.add(
    quote do:
      proc listen*(
          _: typedesc[`typeIdent`], handler: `handlerProcIdent`
      ): Result[`listenerHandleIdent`, string] =
        return `listenImplIdent`(DefaultBrokerContext, handler)

      proc listen*(
          _: typedesc[`typeIdent`],
          brokerCtx: BrokerContext,
          handler: `handlerProcIdent`,
      ): Result[`listenerHandleIdent`, string] =
        return `listenImplIdent`(brokerCtx, handler)

  )

  # ── emit impl ─────────────────────────────────────────────────────────
  result.add(
    quote do:
      proc `emitImplIdent`(
          brokerCtx: BrokerContext, event: `typeIdent`
      ) {.async: (raises: []).} =
        `initProcIdent`()

        when compiles(event.isNil()):
          if event.isNil():
            error "Cannot emit uninitialized event object", eventType = `typeNameLit`
            return

        # Collect targets under lock
        type EvTarget = object
          eventChan: ptr Channel[`eventMsgName`]
          listenerSignal: ThreadSignalPtr
          isSameThread: bool

        var targets: seq[EvTarget] = @[]
        let myThreadId = currentMtThreadId()

        withLock(`globalLockIdent`):
          for i in 0 ..< `globalBucketCountIdent`:
            if `globalBucketsIdent`[i].brokerCtx == brokerCtx and
                `globalBucketsIdent`[i].active and `globalBucketsIdent`[i].hasListeners:
              targets.add(
                EvTarget(
                  eventChan: `globalBucketsIdent`[i].eventChan,
                  listenerSignal: `globalBucketsIdent`[i].listenerSignal,
                  isSameThread: `globalBucketsIdent`[i].threadId == myThreadId,
                )
              )

        if targets.len == 0:
          return

        for target in targets:
          if target.isSameThread:
            # Same-thread: dispatch directly to local listeners via asyncSpawn
            var idx = -1
            for i in 0 ..< `tvListenerCtxIdent`.len:
              if `tvListenerCtxIdent`[i] == brokerCtx:
                idx = i
                break
            if idx >= 0:
              var callbacks: seq[`handlerProcIdent`] = @[]
              for cb in `tvListenerHandlersIdent`[idx].values:
                callbacks.add(cb)
              for cb in callbacks:
                asyncSpawn `listenerTaskIdent`(cb, event)
          else:
            # Cross-thread: send via Channel[T] and wake the listener's dispatcher.
            let msg = `eventMsgName`(kind: `eventMsgKindName`.emkEvent, event: event)
            {.cast(gcsafe).}:
              try:
                target.eventChan[].send(msg)
              except Exception:
                discard
            fireBrokerSignal(target.listenerSignal)

  )

  # ── Public emit ───────────────────────────────────────────────────────
  result.add(
    quote do:
      proc emit*(event: `typeIdent`) {.async: (raises: []).} =
        await `emitImplIdent`(DefaultBrokerContext, event)

      proc emit*(_: typedesc[`typeIdent`], event: `typeIdent`) {.async: (raises: []).} =
        await `emitImplIdent`(DefaultBrokerContext, event)

      proc emit*(
          _: typedesc[`typeIdent`], brokerCtx: BrokerContext, event: `typeIdent`
      ) {.async: (raises: []).} =
        await `emitImplIdent`(brokerCtx, event)

  )

  # ── Field-constructor emit overloads (for inline object types) ────────
  if hasInlineFields:
    let typedescParamType =
      newTree(nnkBracketExpr, ident("typedesc"), copyNimTree(typeIdent))

    let asyncPragma = newTree(
      nnkPragma,
      newTree(
        nnkExprColonExpr,
        ident("async"),
        newTree(
          nnkTupleConstr,
          newTree(nnkExprColonExpr, ident("raises"), newTree(nnkBracket)),
        ),
      ),
    )

    # Default context
    var emitCtorParams = newTree(nnkFormalParams, newEmptyNode())
    emitCtorParams.add(
      newTree(nnkIdentDefs, ident("_"), typedescParamType, newEmptyNode())
    )
    for i in 0 ..< fieldNames.len:
      emitCtorParams.add(
        newTree(
          nnkIdentDefs,
          copyNimTree(fieldNames[i]),
          copyNimTree(fieldTypes[i]),
          newEmptyNode(),
        )
      )

    var emitCtorExpr = newTree(nnkObjConstr, copyNimTree(typeIdent))
    for i in 0 ..< fieldNames.len:
      emitCtorExpr.add(
        newTree(
          nnkExprColonExpr, copyNimTree(fieldNames[i]), copyNimTree(fieldNames[i])
        )
      )

    let emitCtorCallDefault =
      newCall(copyNimTree(emitImplIdent), ident("DefaultBrokerContext"), emitCtorExpr)
    let emitCtorBodyDefault = quote:
      await `emitCtorCallDefault`

    let typedescEmitProcDefault = newTree(
      nnkProcDef,
      postfix(ident("emit"), "*"),
      newEmptyNode(),
      newEmptyNode(),
      emitCtorParams,
      copyNimTree(asyncPragma),
      newEmptyNode(),
      emitCtorBodyDefault,
    )
    result.add(typedescEmitProcDefault)

    # With BrokerContext
    var emitCtorParamsCtx = newTree(nnkFormalParams, newEmptyNode())
    emitCtorParamsCtx.add(
      newTree(nnkIdentDefs, ident("_"), typedescParamType, newEmptyNode())
    )
    emitCtorParamsCtx.add(
      newTree(nnkIdentDefs, ident("brokerCtx"), ident("BrokerContext"), newEmptyNode())
    )
    for i in 0 ..< fieldNames.len:
      emitCtorParamsCtx.add(
        newTree(
          nnkIdentDefs,
          copyNimTree(fieldNames[i]),
          copyNimTree(fieldTypes[i]),
          newEmptyNode(),
        )
      )

    let emitCtorCallCtx =
      newCall(copyNimTree(emitImplIdent), ident("brokerCtx"), copyNimTree(emitCtorExpr))
    let emitCtorBodyCtx = quote:
      await `emitCtorCallCtx`

    let typedescEmitProcCtx = newTree(
      nnkProcDef,
      postfix(ident("emit"), "*"),
      newEmptyNode(),
      newEmptyNode(),
      emitCtorParamsCtx,
      copyNimTree(asyncPragma),
      newEmptyNode(),
      emitCtorBodyCtx,
    )
    result.add(typedescEmitProcCtx)

  # ── dropListener impl ─────────────────────────────────────────────────
  result.add(
    quote do:
      proc `dropListenerImplIdent`(
          brokerCtx: BrokerContext, handle: `listenerHandleIdent`
      ) =
        if handle.id == 0'u64:
          return
        if handle.threadId != currentMtThreadId():
          error "dropListener called from wrong thread",
            eventType = `typeNameLit`,
            handleThread = repr(handle.threadId),
            currentThread = repr(currentMtThreadId())
          return

        var tvIdx = -1
        for i in 0 ..< `tvListenerCtxIdent`.len:
          if `tvListenerCtxIdent`[i] == brokerCtx:
            tvIdx = i
            break
        if tvIdx < 0:
          return

        `tvListenerHandlersIdent`[tvIdx].del(handle.id)

        if `tvListenerHandlersIdent`[tvIdx].len == 0:
          `tvListenerCtxIdent`.del(tvIdx)
          `tvListenerHandlersIdent`.del(tvIdx)
          `tvNextIdsIdent`.del(tvIdx)

          let myThreadId = currentMtThreadId()
          let myThreadGen = currentMtThreadGen()
          withLock(`globalLockIdent`):
            for i in 0 ..< `globalBucketCountIdent`:
              if `globalBucketsIdent`[i].brokerCtx == brokerCtx and
                  `globalBucketsIdent`[i].threadId == myThreadId and
                  `globalBucketsIdent`[i].threadGen == myThreadGen:
                `globalBucketsIdent`[i].hasListeners = false
                break

  )

  # ── dropAllListeners impl ─────────────────────────────────────────────
  result.add(
    quote do:
      proc `dropAllListenersImplIdent`(brokerCtx: BrokerContext) =
        `initProcIdent`()

        let myThreadId = currentMtThreadId()
        var chansToClear: seq[(ptr Channel[`eventMsgName`], ThreadSignalPtr)] = @[]

        withLock(`globalLockIdent`):
          for i in 0 ..< `globalBucketCountIdent`:
            if `globalBucketsIdent`[i].brokerCtx == brokerCtx and
                `globalBucketsIdent`[i].hasListeners:
              `globalBucketsIdent`[i].hasListeners = false
              if `globalBucketsIdent`[i].threadId != myThreadId:
                chansToClear.add(
                  (
                    `globalBucketsIdent`[i].eventChan,
                    `globalBucketsIdent`[i].listenerSignal,
                  )
                )

        # Clean local threadvar entries
        var tvIdx = -1
        for i in 0 ..< `tvListenerCtxIdent`.len:
          if `tvListenerCtxIdent`[i] == brokerCtx:
            tvIdx = i
            break
        if tvIdx >= 0:
          `tvListenerHandlersIdent`[tvIdx].clear()
          `tvListenerCtxIdent`.del(tvIdx)
          `tvListenerHandlersIdent`.del(tvIdx)
          `tvNextIdsIdent`.del(tvIdx)

        # Send emkClearListeners to remote-thread channels.
        for (chan, sig) in chansToClear:
          {.cast(gcsafe).}:
            try:
              chan[].send(`eventMsgName`(kind: `eventMsgKindName`.emkClearListeners))
            except Exception:
              discard
          fireBrokerSignal(sig)

  )

  # ── Public dropListener / dropAllListeners ────────────────────────────
  result.add(
    quote do:
      proc dropListener*(_: typedesc[`typeIdent`], handle: `listenerHandleIdent`) =
        `dropListenerImplIdent`(DefaultBrokerContext, handle)

      proc dropListener*(
          _: typedesc[`typeIdent`],
          brokerCtx: BrokerContext,
          handle: `listenerHandleIdent`,
      ) =
        `dropListenerImplIdent`(brokerCtx, handle)

      proc dropAllListeners*(_: typedesc[`typeIdent`]) =
        `dropAllListenersImplIdent`(DefaultBrokerContext)

      proc dropAllListeners*(_: typedesc[`typeIdent`], brokerCtx: BrokerContext) =
        `dropAllListenersImplIdent`(brokerCtx)

  )

  # ── shutdownProcessLoopsForCtx (used by API teardown) ─────────────────
  # Sends emkShutdown to all poll fns for the given context on the current thread,
  # awaits their shutdown futures, then drains any in-flight listener futures.
  # Must be called from the same thread that registered the listeners.
  result.add(
    quote do:
      proc `shutdownProcessLoopsForCtxIdent`(
          ctx: BrokerContext
      ) {.async: (raises: []).} =
        let myThreadId = currentMtThreadId()
        let myThreadGen = currentMtThreadGen()
        var chansToShutdown: seq[(ptr Channel[`eventMsgName`], ThreadSignalPtr)] = @[]
        withLock(`globalLockIdent`):
          for i in 0 ..< `globalBucketCountIdent`:
            if `globalBucketsIdent`[i].brokerCtx == ctx and
                `globalBucketsIdent`[i].threadId == myThreadId and
                `globalBucketsIdent`[i].threadGen == myThreadGen and
                `globalBucketsIdent`[i].active:
              chansToShutdown.add(
                (
                  `globalBucketsIdent`[i].eventChan,
                  `globalBucketsIdent`[i].listenerSignal,
                )
              )
              `globalBucketsIdent`[i].active = false

        # Collect shutdown futures BEFORE sending (they're in tvShutdownFutsIdent).
        var shutdownFuts: seq[Future[void]] = @[]
        var i = 0
        while i < `tvShutdownFutsIdent`.len:
          if `tvShutdownFutsIdent`[i][0] == ctx:
            shutdownFuts.add(`tvShutdownFutsIdent`[i][1])
            `tvShutdownFutsIdent`.del(i)
          else:
            inc i

        # Send emkShutdown and wake the listener thread's dispatcher.
        for (chan, sig) in chansToShutdown:
          {.cast(gcsafe).}:
            try:
              chan[].send(`eventMsgName`(kind: `eventMsgKindName`.emkShutdown))
            except Exception:
              discard
          fireBrokerSignal(sig)

        # Await shutdown confirmation (poll fn processed emkShutdown).
        for fut in shutdownFuts:
          if not fut.finished():
            try:
              discard await withTimeout(fut, chronos.seconds(5))
            except CatchableError:
              discard

        # Drain in-flight listener futures for this context.
        var j = 0
        while j < `tvListenerFutsIdent`.len:
          if `tvListenerFutsIdent`[j][0] == ctx:
            let fut = `tvListenerFutsIdent`[j][1]
            if not fut.finished():
              try:
                discard await withTimeout(fut, chronos.seconds(5))
              except CatchableError:
                discard
            `tvListenerFutsIdent`.del(j)
          else:
            inc j

  )

  when defined(brokerDebug):
    echo result.repr
