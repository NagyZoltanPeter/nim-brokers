## Multi-Thread EventBroker
## -----------------------
## Generates a multi-thread capable EventBroker where listeners can be registered
## on any thread and events can be emitted from any thread. Events are delivered
## to all registered listeners across all threads (broadcast fan-out).
##
## Same-thread listeners bypass channels and are dispatched directly via asyncSpawn.
## Cross-thread delivery uses AsyncChannel per listener-thread.
##
## The broker does NOT own or spawn threads — that is the user's responsibility.
## The global registry uses `createShared` / raw pointers so it is safe under
## both `--mm:orc` and `--mm:refc`.
##
## Listener closures are stored in threadvars (GC-managed, per-thread) rather
## than in the shared bucket, avoiding the need to cast closures to raw pointers.
##
## `dropListener` must be called from the thread that registered the listener.
## `dropAllListeners` can be called from any thread — it sends shutdown to all
## listener threads for the context, and each processLoop drains in-flight tasks
## and cleans up its own threadvars.

{.push raises: [].}

import std/[macros, locks, tables]
import chronos, chronicles
import results
import asyncchannels
import ./helper/broker_utils, ./broker_context, ./mt_broker_common

export results, chronos, broker_context, asyncchannels, chronicles, mt_broker_common

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

  let eventMsgName = ident(typeDisplayName & "MtEventMsg")
  let bucketName = ident(typeDisplayName & "MtEventBucket")

  let globalBucketsIdent = ident("g" & typeDisplayName & "MtBuckets")
  let globalBucketCountIdent = ident("g" & typeDisplayName & "MtBucketCount")
  let globalBucketCapIdent = ident("g" & typeDisplayName & "MtBucketCap")
  let globalLockIdent = ident("g" & typeDisplayName & "MtLock")
  let globalInitIdent = ident("g" & typeDisplayName & "MtInit")

  let initProcIdent = ident("ensureInit" & typeDisplayName & "MtBroker")
  let growProcIdent = ident("grow" & typeDisplayName & "MtBuckets")
  let processLoopIdent = ident("processLoop" & typeDisplayName)
  let listenerTaskIdent = ident("notify" & typeDisplayName & "Listener")

  let tvListenerCtxIdent = ident("g" & typeDisplayName & "TvListenerCtxs")
  let tvListenerHandlersIdent = ident("g" & typeDisplayName & "TvListenerHandlers")
  let tvNextIdsIdent = ident("g" & typeDisplayName & "TvNextIds")

  let listenImplIdent = ident("listen" & typeDisplayName & "MtImpl")
  let emitImplIdent = ident("emit" & typeDisplayName & "MtImpl")
  let dropListenerImplIdent = ident("drop" & typeDisplayName & "MtListenerImpl")
  let dropAllListenersImplIdent = ident("dropAll" & typeDisplayName & "MtListenersImpl")

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

        `eventMsgName` = object
          isShutdown: bool
          event: `typeIdent`

        `bucketName` = object
          brokerCtx: BrokerContext
          eventChan: ptr AsyncChannel[`eventMsgName`]
          threadId: pointer
          active: bool
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
          `globalBucketsIdent` = cast[ptr UncheckedArray[`bucketName`]](
            createShared(`bucketName`, `globalBucketCapIdent`)
          )
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
        let newBuf = cast[ptr UncheckedArray[`bucketName`]](
          createShared(`bucketName`, newCap)
        )
        for i in 0 ..< `globalBucketCountIdent`:
          newBuf[i] = `globalBucketsIdent`[i]
        deallocShared(`globalBucketsIdent`)
        `globalBucketsIdent` = newBuf
        `globalBucketCapIdent` = newCap
  )

  # ── Threadvar listener storage ────────────────────────────────────────
  # Parallel seqs: contexts, handler tables, next-ID counters.
  # Index i corresponds to one (BrokerContext, this-thread) listener group.
  result.add(
    quote do:
      var `tvListenerCtxIdent` {.threadvar.}: seq[BrokerContext]
      var `tvListenerHandlersIdent` {.threadvar.}: seq[Table[uint64, `handlerProcIdent`]]
      var `tvNextIdsIdent` {.threadvar.}: seq[uint64]
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
            eventType = `typeNameLit`,
            error = getCurrentExceptionMsg()
  )

  # ── Process loop ──────────────────────────────────────────────────────
  # Runs on the listener thread. Receives events from cross-thread emitters
  # and dispatches to local listeners. Tracks in-flight futures for clean shutdown.
  let ecIdent = ident("eventChan")
  let loopCtxIdent = ident("loopCtx")
  let ecPtrType = quote:
    ptr AsyncChannel[`eventMsgName`]

  result.add(
    quote do:
      proc `processLoopIdent`(
          `ecIdent`: `ecPtrType`,
          `loopCtxIdent`: BrokerContext,
      ) {.async: (raises: []).} =
        var inFlight: seq[Future[void]] = @[]
        while true:
          let recvRes = catch:
            await `ecIdent`.recv()
          if recvRes.isErr():
            break
          let msg = recvRes.get()
          if msg.isShutdown:
            # Drain in-flight listeners before exiting
            for fut in inFlight:
              if not fut.finished():
                try:
                  discard await withTimeout(fut, chronos.seconds(5))
                except CatchableError:
                  discard
            # Clean up threadvar entries for this context (safe: we're on the owning thread)
            for i in 0 ..< `tvListenerCtxIdent`.len:
              if `tvListenerCtxIdent`[i] == `loopCtxIdent`:
                `tvListenerHandlersIdent`[i].clear()
                `tvListenerCtxIdent`.del(i)
                `tvListenerHandlersIdent`.del(i)
                `tvNextIdsIdent`.del(i)
                break
            break

          # Prune completed futures — await marks them as consumed so Chronos
          # does not warn about unresolved futures.  The await is instant
          # because the future has already finished.
          var j = 0
          while j < inFlight.len:
            if inFlight[j].finished():
              try:
                await inFlight[j]      # instant — consumes the future
              except CatchableError:
                discard                # notifyListener is raises:[], but Chronos needs the guard
              inFlight.del(j)
            else:
              inc j

          # Dispatch to all local listeners for this context.
          # Calling the async proc schedules it on the event loop and returns
          # a Future immediately — no asyncSpawn needed.  We track the future
          # in inFlight so we can (a) consume it on prune and (b) drain it
          # on shutdown.
          var idx = -1
          for i in 0 ..< `tvListenerCtxIdent`.len:
            if `tvListenerCtxIdent`[i] == `loopCtxIdent`:
              idx = i
              break
          if idx >= 0:
            var callbacks: seq[`handlerProcIdent`] = @[]
            for cb in `tvListenerHandlersIdent`[idx].values:
              callbacks.add(cb)
            for cb in callbacks:
              # Schedule listener — returns Future, already on the event loop.
              let fut = `listenerTaskIdent`(cb, msg.event)
              inFlight.add(fut)
        # After loop: we do NOT close or deallocShared the channel here.
        # A concurrent emitter may still hold a pointer captured before the
        # bucket was removed from the registry, and sendSync on a closed
        # channel is undefined behavior. Leaving it open is safe: the channel
        # is drained, nobody reads from it, and the small per-channel leak
        # only occurs at teardown.
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

        # Ensure a bucket + channel exists for (brokerCtx, this thread)
        let myThreadId = currentMtThreadId()
        var bucketExists = false
        var spawnChan: ptr AsyncChannel[`eventMsgName`]
        withLock(`globalLockIdent`):
          for i in 0 ..< `globalBucketCountIdent`:
            if `globalBucketsIdent`[i].brokerCtx == brokerCtx and
               `globalBucketsIdent`[i].threadId == myThreadId and
               `globalBucketsIdent`[i].active:
              bucketExists = true
              break
          if not bucketExists:
            if `globalBucketCountIdent` >= `globalBucketCapIdent`:
              `growProcIdent`()
            let chan = cast[ptr AsyncChannel[`eventMsgName`]](
              createShared(AsyncChannel[`eventMsgName`], 1)
            )
            discard chan[].open()
            let idx = `globalBucketCountIdent`
            `globalBucketsIdent`[idx] = `bucketName`(
              brokerCtx: brokerCtx,
              eventChan: chan,
              threadId: myThreadId,
              active: true,
            )
            `globalBucketCountIdent` += 1
            spawnChan = chan
        # asyncSpawn outside lock to prevent potential deadlock if
        # processLoop or its listeners acquire the same lock.
        if not bucketExists:
          asyncSpawn `processLoopIdent`(spawnChan, brokerCtx)

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
  # emit is an async proc. Callers in async contexts use `await`;
  # callers in {.thread.} procs with no event loop use `waitFor`.
  # - Cross-thread: async channel send (non-blocking on event loop)
  # - Same-thread: asyncSpawn to local listeners (fire-and-forget)
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
          eventChan: ptr AsyncChannel[`eventMsgName`]
          isSameThread: bool

        var targets: seq[EvTarget] = @[]
        let myThreadId = currentMtThreadId()

        withLock(`globalLockIdent`):
          for i in 0 ..< `globalBucketCountIdent`:
            if `globalBucketsIdent`[i].brokerCtx == brokerCtx and
               `globalBucketsIdent`[i].active:
              targets.add(EvTarget(
                eventChan: `globalBucketsIdent`[i].eventChan,
                isSameThread: `globalBucketsIdent`[i].threadId == myThreadId,
              ))

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
            # Cross-thread: send via channel (sendSync is brief — buffer + signal)
            let msg = `eventMsgName`(isShutdown: false, event: event)
            target.eventChan[].sendSync(msg)
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

    # Async pragma: {.async: (raises: []).}
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
      newCall(
        copyNimTree(emitImplIdent), ident("brokerCtx"), copyNimTree(emitCtorExpr)
      )
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
        # Enforce: must be called from the thread that registered the listener
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

        # If no more listeners for this context on this thread, shut down channel
        if `tvListenerHandlersIdent`[tvIdx].len == 0:
          `tvListenerCtxIdent`.del(tvIdx)
          `tvListenerHandlersIdent`.del(tvIdx)
          `tvNextIdsIdent`.del(tvIdx)

          var chanToShutdown: ptr AsyncChannel[`eventMsgName`]
          let myThreadId = currentMtThreadId()
          withLock(`globalLockIdent`):
            for i in 0 ..< `globalBucketCountIdent`:
              if `globalBucketsIdent`[i].brokerCtx == brokerCtx and
                 `globalBucketsIdent`[i].threadId == myThreadId:
                chanToShutdown = `globalBucketsIdent`[i].eventChan
                `globalBucketsIdent`[i].active = false
                # Shift remaining buckets
                for j in i ..< `globalBucketCountIdent` - 1:
                  `globalBucketsIdent`[j] = `globalBucketsIdent`[j + 1]
                `globalBucketCountIdent` -= 1
                break
          if not chanToShutdown.isNil():
            chanToShutdown[].sendSync(`eventMsgName`(isShutdown: true))
  )

  # ── dropAllListeners impl ─────────────────────────────────────────────
  # Callable from any thread. Shuts down ALL listener threads for this context.
  result.add(
    quote do:
      proc `dropAllListenersImplIdent`(brokerCtx: BrokerContext) =
        `initProcIdent`()

        # Phase 1: Under lock, collect all channels for this context and remove buckets
        var chansToShutdown: seq[ptr AsyncChannel[`eventMsgName`]] = @[]

        withLock(`globalLockIdent`):
          var i = 0
          while i < `globalBucketCountIdent`:
            if `globalBucketsIdent`[i].brokerCtx == brokerCtx:
              chansToShutdown.add(`globalBucketsIdent`[i].eventChan)
              `globalBucketsIdent`[i].active = false
              # Shift remaining
              for j in i ..< `globalBucketCountIdent` - 1:
                `globalBucketsIdent`[j] = `globalBucketsIdent`[j + 1]
              `globalBucketCountIdent` -= 1
              # Don't increment i — next element shifted into this position
            else:
              inc i

        # Phase 2: Clean up local threadvar entries if current thread has listeners
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

        # Phase 3: Send shutdown to all collected channels
        # Each processLoop will drain in-flight tasks and clean its own threadvars
        for chan in chansToShutdown:
          chan[].sendSync(`eventMsgName`(isShutdown: true))
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

  when defined(brokerDebug):
    echo result.repr
