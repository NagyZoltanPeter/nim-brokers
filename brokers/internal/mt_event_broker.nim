## Multi-Thread EventBroker
## ------------------------
## Generates a multi-thread capable EventBroker where listeners can be
## registered on any thread and events can be emitted from any thread.
## Events are delivered to all registered listeners across all threads
## (broadcast fan-out).
##
## Same-thread emit→listener dispatch bypasses the ring and is delivered
## directly via `asyncSpawn`. Cross-thread delivery uses a lock-free
## Vyukov MPSC ring + a global per-broker-type slab with refcounted
## payload cells (so one emit shares one cell across N listener threads
## via atomic refcount, rather than N deep-copies).
##
## See `doc/REFACTOR_MT_QUEUE.md` for the full design; this file is the
## EventBroker integration of Phase 2+3 of that plan.
##
## §2.6 safety contract honored by construction (Invariant I0):
##   - The bucket-owning thread (the listener thread) allocates its ring
##     via `createShared` and frees it via `shutdown(ctx)` on the same
##     thread.
##   - The global event slab is allocated lazily, by whichever thread
##     first calls `listen()` or `emit()`. That thread MUST outlive the
##     slab.
##   - Sender threads only ever touch atomics + memcpy + signal-fire —
##     never the Nim allocator on the hot path.

{.push raises: [].}

import std/[macros, locks, tables, atomics]
import chronos, chronicles
import results
import
  ./helper/broker_utils,
  ../broker_context,
  ./mt_broker_common,
  ./mt_queue,
  ./mt_codec,
  ./mt_config

export results, chronos, broker_context, chronicles, mt_broker_common, mt_config

# Ring-slot sentinel: a slot's payload `uint32` is normally a slab cell
# index, but this reserved value carries a "clear local tvHandlers"
# control signal instead.  Shutdown is communicated via the ring's
# `closed` flag, not a sentinel, because `tryEnqueue` rejects when
# closed and we don't want shutdown to compete with that.
#
# The sentinel lives in the same namespace as cell indices and MUST be
# larger than any legal slab capacity (bounded by uint32 in practice).
const CtrlClearListeners*: uint32 = high(uint32) - 1

# Capacity defaults moved to `mt_config.nim`; they remain re-exported via
# the `mt_config` module so external code referencing
# `DefaultMtEvtQueueDepth` etc. still resolves.

# ---------------------------------------------------------------------------
# Macro code generator
# ---------------------------------------------------------------------------

proc generateMtEventBroker*(
    body: NimNode, cfg: MtEvtCfg = defaultMtEvtCfg()
): NimNode =
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

  when not defined(brokerConfigSilent):
    hint(fmtEvtCfgSummary(typeDisplayName, cfg))

  # ── Identifier setup ──────────────────────────────────────────────────
  let handlerProcIdent = ident(typeDisplayName & "ListenerProc")
  let listenerHandleIdent = ident(typeDisplayName & "Listener")
  let exportedHandlerProcIdent = postfix(copyNimTree(handlerProcIdent), "*")
  let exportedListenerHandleIdent = postfix(copyNimTree(listenerHandleIdent), "*")

  let bucketName = ident(typeDisplayName & "MtEventBucket")

  let globalBucketsIdent = ident("g" & typeDisplayName & "MtBuckets")
  let globalBucketCountIdent = ident("g" & typeDisplayName & "MtBucketCount")
  let globalBucketCapIdent = ident("g" & typeDisplayName & "MtBucketCap")
  let globalLockIdent = ident("g" & typeDisplayName & "MtLock")
  let globalInitIdent = ident("g" & typeDisplayName & "MtInit")

  let globalSlabIdent = ident("g" & typeDisplayName & "MtSlab")
  let globalSlabInitIdent = ident("g" & typeDisplayName & "MtSlabInit")

  let initProcIdent = ident("ensureInit" & typeDisplayName & "MtBroker")
  let initSlabProcIdent = ident("ensureSlab" & typeDisplayName & "MtBroker")
  let growProcIdent = ident("grow" & typeDisplayName & "MtBuckets")
  let listenerTaskIdent = ident("notify" & typeDisplayName & "Listener")
  let pollFnMakerIdent = ident("makePollFn" & typeDisplayName)
  let clearListenersIdent = ident("clearListeners" & typeDisplayName)
  let releaseCellIdent = ident("releaseCell" & typeDisplayName)
  let shardHintIdent = ident("shardHint" & typeDisplayName)

  let marshalIdent = ident(typeDisplayName & "MtMarshal")
  let unmarshalIdent = ident(typeDisplayName & "MtUnmarshal")

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

  let queueDepthLit = newLit(cfg.queueDepth)
  let slabCapacityLit = newLit(cfg.slabCapacity)
  let payloadBytesLit = newLit(cfg.maxPayloadBytes)
  let freeListShardsLit = newLit(uint32(cfg.freeListShards))

  result = newStmtList()

  # ── Type section ──────────────────────────────────────────────────────
  result.add(
    quote do:
      type
        `exportedTypeIdent` = `objectDef`
        `exportedListenerHandleIdent` = object
          id*: uint64
          threadId*: pointer ## Thread that registered this listener.

        `exportedHandlerProcIdent` =
          proc(event: `typeIdent`): Future[void] {.async: (raises: []), gcsafe.}

        `bucketName` = object
          brokerCtx: BrokerContext
          ring: ptr VyukovMpscRing[uint32]
          listenerSignal: ThreadSignalPtr
          threadId: pointer
          threadGen: uint64 ## disambiguates reused threadvar addresses
          active: bool
          hasListeners: bool

  )

  # ── Codec procs (marshal / unmarshal) ─────────────────────────────────
  for procNode in genMtCodecProcs(marshalIdent, unmarshalIdent, typeIdent):
    result.add(procNode)

  # ── Global shared state ───────────────────────────────────────────────
  result.add(
    quote do:
      var `globalBucketsIdent`: ptr UncheckedArray[`bucketName`]
      var `globalBucketCountIdent`: int
      var `globalBucketCapIdent`: int
      var `globalLockIdent`: Lock
      var `globalInitIdent`: Atomic[int]
        ## 0 = uninitialised, 1 = initialising, 2 = ready. CAS(0→1) wins;
        ## losers spin until 2.
      var `globalSlabIdent`: PayloadSlab
      var `globalSlabInitIdent`: Atomic[int]
        ## same protocol as `globalInitIdent`, gating the global slab.
  )

  # ── Init helpers ──────────────────────────────────────────────────────
  result.add(
    quote do:
      proc `initSlabProcIdent`() =
        ## Lazy-init the global event slab on first listen() or emit().
        ## The caller's thread becomes the slab's owner (must outlive it).
        if `globalSlabInitIdent`.load(moRelaxed) == 2:
          return
        var expected = 0
        if `globalSlabInitIdent`.compareExchange(
          expected, 1, moAcquire, moRelaxed
        ):
          initPayloadSlab(
            `globalSlabIdent`,
            capacity = uint32(`slabCapacityLit`),
            payloadBytes = uint32(`payloadBytesLit`),
            nShards = `freeListShardsLit`,
          )
          `globalSlabInitIdent`.store(2, moRelease)
        else:
          while `globalSlabInitIdent`.load(moAcquire) != 2:
            discard

      proc `initProcIdent`() =
        if `globalInitIdent`.load(moRelaxed) == 2:
          `initSlabProcIdent`()
          return
        var expected = 0
        if `globalInitIdent`.compareExchange(expected, 1, moAcquire, moRelaxed):
          initLock(`globalLockIdent`)
          `globalBucketCapIdent` = 4
          `globalBucketsIdent` = cast[ptr UncheckedArray[`bucketName`]](
            createShared(`bucketName`, `globalBucketCapIdent`)
          )
          `globalBucketCountIdent` = 0
          `globalInitIdent`.store(2, moRelease)
        else:
          while `globalInitIdent`.load(moAcquire) != 2:
            discard
        `initSlabProcIdent`()

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
        # Intentional leak of the old buffer: see mt_request_broker.nim.
        `globalBucketsIdent` = newBuf
        `globalBucketCapIdent` = newCap

  )

  # ── Threadvar listener storage ────────────────────────────────────────
  result.add(
    quote do:
      var `tvListenerCtxIdent` {.threadvar.}: seq[BrokerContext]
      var `tvListenerHandlersIdent` {.threadvar.}:
        seq[Table[uint64, `handlerProcIdent`]]
      var `tvNextIdsIdent` {.threadvar.}: seq[uint64]
      var `tvListenerFutsIdent` {.threadvar.}: seq[(BrokerContext, Future[void])]
      var `tvShutdownFutsIdent` {.threadvar.}: seq[(BrokerContext, Future[void])]
  )

  # ── Listener task ─────────────────────────────────────────────────────
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

  # ── Local helpers used by both same-thread emit and cross-thread poll
  result.add(
    quote do:
      proc `shardHintIdent`(): uint32 {.inline.} =
        ## Hash of the calling thread's TLS marker → free-list shard.
        cast[uint32](cast[uint](currentMtThreadId()) shr 4)

      proc `clearListenersIdent`(loopCtx: BrokerContext) {.gcsafe, raises: [].} =
        {.cast(gcsafe).}:
          for i in 0 ..< `tvListenerCtxIdent`.len:
            if `tvListenerCtxIdent`[i] == loopCtx:
              `tvListenerHandlersIdent`[i].clear()
              `tvListenerCtxIdent`.del(i)
              `tvListenerHandlersIdent`.del(i)
              `tvNextIdsIdent`.del(i)
              break

      proc `releaseCellIdent`(cellIdx: uint32) {.inline, gcsafe.} =
        if `globalSlabIdent`.decRefAndCheck(cellIdx):
          `globalSlabIdent`.release(cellIdx, `shardHintIdent`())

  )

  # ── Poll fn maker ─────────────────────────────────────────────────────
  result.add(
    quote do:
      proc `pollFnMakerIdent`(
          ring: ptr VyukovMpscRing[uint32],
          loopCtx: BrokerContext,
          shutdownFut: Future[void],
      ): ThreadDispatchPollFn =
        let capturedRing = ring
        let capturedCtx = loopCtx
        let capturedShutdownFut = shutdownFut
        return proc(): int {.gcsafe, raises: [].} =
          {.cast(gcsafe).}:
            var cellIdx: uint32
            if not capturedRing.tryDequeue(cellIdx):
              # Empty.  If the ring has been closed by shutdown, this is
              # the definitive "drained" point (no more producers can
              # enqueue past `closed=true`).  Complete the shutdown
              # future and self-unregister.
              if capturedRing.isClosed():
                if not capturedShutdownFut.finished:
                  capturedShutdownFut.complete()
                return 2
              return 0
            case cellIdx
            of CtrlClearListeners:
              `clearListenersIdent`(capturedCtx)
              return 1
            else:
              # Normal cell: decode, dispatch, decRef.
              var ev: `typeIdent`
              let cellPtr = `globalSlabIdent`.cellPtr(cellIdx)
              let payloadPtr = `globalSlabIdent`.cellPayloadPtr(cellIdx)
              let ok =
                try:
                  `unmarshalIdent`(payloadPtr, int(cellPtr.payloadSize), ev)
                except Exception:
                  false
              if ok:
                var idx = -1
                for i in 0 ..< `tvListenerCtxIdent`.len:
                  if `tvListenerCtxIdent`[i] == capturedCtx:
                    idx = i
                    break
                if idx >= 0:
                  var callbacks: seq[`handlerProcIdent`] = @[]
                  for cb in `tvListenerHandlersIdent`[idx].values:
                    callbacks.add(cb)
                  for cb in callbacks:
                    let fut: Future[void] = `listenerTaskIdent`(cb, ev)
                    `tvListenerFutsIdent`.add((capturedCtx, fut))
                    asyncSpawn fut
              else:
                error "Failed to unmarshal event payload",
                  eventType = `typeNameLit`
              `releaseCellIdent`(cellIdx)
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

        if `tvNextIdsIdent`[tvIdx] == high(uint64):
          return err("Cannot add more listeners: ID space exhausted")
        let newId = `tvNextIdsIdent`[tvIdx]
        `tvNextIdsIdent`[tvIdx] += 1
        `tvListenerHandlersIdent`[tvIdx][newId] = handler

        # Ensure a bucket + ring exists for (brokerCtx, this thread).
        let myThreadId = currentMtThreadId()
        let myThreadGen = currentMtThreadGen()
        var bucketExists = false
        var spawnRing: ptr VyukovMpscRing[uint32]
        withLock(`globalLockIdent`):
          for i in 0 ..< `globalBucketCountIdent`:
            if `globalBucketsIdent`[i].brokerCtx == brokerCtx and
                `globalBucketsIdent`[i].threadId == myThreadId and
                `globalBucketsIdent`[i].threadGen == myThreadGen:
              `globalBucketsIdent`[i].hasListeners = true
              `globalBucketsIdent`[i].active = true
              bucketExists = true
              break
          if not bucketExists:
            if `globalBucketCountIdent` >= `globalBucketCapIdent`:
              `growProcIdent`()
            let ring = newVyukovMpscRing[uint32](`queueDepthLit`)
            let listenerSig = getOrInitBrokerSignal()
            let idx = `globalBucketCountIdent`
            `globalBucketsIdent`[idx] = `bucketName`(
              brokerCtx: brokerCtx,
              ring: ring,
              listenerSignal: listenerSig,
              threadId: myThreadId,
              threadGen: myThreadGen,
              active: true,
              hasListeners: true,
            )
            `globalBucketCountIdent` += 1
            spawnRing = ring

        if not bucketExists and not spawnRing.isNil:
          let shutdownFut =
            newFuture[void]("eventBroker." & `typeNameLit` & ".shutdown")
          `tvShutdownFutsIdent`.add((brokerCtx, shutdownFut))
          registerBrokerPoller(`pollFnMakerIdent`(spawnRing, brokerCtx, shutdownFut))
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

        type CrossTarget = object
          ring: ptr VyukovMpscRing[uint32]
          signal: ThreadSignalPtr

        var crossTargets: seq[CrossTarget] = @[]
        var hasSameThread = false
        let myThreadId = currentMtThreadId()
        let myThreadGen = currentMtThreadGen()

        withLock(`globalLockIdent`):
          for i in 0 ..< `globalBucketCountIdent`:
            if `globalBucketsIdent`[i].brokerCtx == brokerCtx and
                `globalBucketsIdent`[i].active and `globalBucketsIdent`[i].hasListeners:
              if `globalBucketsIdent`[i].threadId == myThreadId and
                  `globalBucketsIdent`[i].threadGen == myThreadGen:
                hasSameThread = true
              else:
                crossTargets.add(
                  CrossTarget(
                    ring: `globalBucketsIdent`[i].ring,
                    signal: `globalBucketsIdent`[i].listenerSignal,
                  )
                )

        # Same-thread fast path: bypass ring entirely.
        if hasSameThread:
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
              let fut: Future[void] = `listenerTaskIdent`(cb, event)
              `tvListenerFutsIdent`.add((brokerCtx, fut))
              asyncSpawn fut

        if crossTargets.len == 0:
          return

        # Cross-thread fan-out via shared refcounted cell.
        let shardHint = `shardHintIdent`()
        let cellIdx = `globalSlabIdent`.claim(shardHint)
        if cellIdx == EmptyIdx:
          warn "event dropped: slab exhausted",
            eventType = `typeNameLit`, targets = crossTargets.len
          return

        let cell = `globalSlabIdent`.cellPtr(cellIdx)
        let payloadPtr = `globalSlabIdent`.cellPayloadPtr(cellIdx)
        let written =
          try:
            `marshalIdent`(payloadPtr, int(`globalSlabIdent`.cellPayloadCap), event)
          except Exception:
            -1
        if written < 0:
          error "event payload exceeds maxPayloadBytes",
            eventType = `typeNameLit`,
            cap = `globalSlabIdent`.cellPayloadCap
          `globalSlabIdent`.release(cellIdx, shardHint)
          return
        cell.payloadSize = uint16(written)
        cell.refcount.store(crossTargets.len, moRelease)

        for target in crossTargets:
          if not target.ring.tryEnqueue(cellIdx):
            warn "event dropped: listener queue full",
              eventType = `typeNameLit`
            `releaseCellIdent`(cellIdx)
          else:
            fireBrokerSignal(target.signal)

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
  # Same-thread: clears tvHandlers immediately + flips flag under lock.
  # Cross-thread: flips flag + pushes a CtrlClearListeners sentinel into
  # the bucket's ring so the listener thread clears its tvHandlers on
  # the next poll cycle.
  result.add(
    quote do:
      proc `dropAllListenersImplIdent`(brokerCtx: BrokerContext) =
        `initProcIdent`()

        let myThreadId = currentMtThreadId()
        var crossRings: seq[(ptr VyukovMpscRing[uint32], ThreadSignalPtr)] = @[]

        withLock(`globalLockIdent`):
          for i in 0 ..< `globalBucketCountIdent`:
            if `globalBucketsIdent`[i].brokerCtx == brokerCtx and
                `globalBucketsIdent`[i].hasListeners:
              `globalBucketsIdent`[i].hasListeners = false
              if `globalBucketsIdent`[i].threadId != myThreadId:
                crossRings.add(
                  (
                    `globalBucketsIdent`[i].ring,
                    `globalBucketsIdent`[i].listenerSignal,
                  )
                )

        # Same-thread tv clear.
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

        # Cross-thread: send control sentinel.
        for (ring, sig) in crossRings:
          discard ring.tryEnqueue(CtrlClearListeners)
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

  # ── shutdownProcessLoopsForCtx (internal; used by API teardown) ───────
  # Must run on the bucket-owning thread. Drains the bucket's ring,
  # decRefs remaining cells, removes the bucket from the registry, and
  # deallocs its ring. The owner thread is the only safe deallocator
  # (Invariant I0).
  result.add(
    quote do:
      proc `shutdownProcessLoopsForCtxIdent`(
          ctx: BrokerContext
      ) {.async: (raises: []).} =
        let myThreadId = currentMtThreadId()
        let myThreadGen = currentMtThreadGen()
        var ringsToShutdown:
          seq[(ptr VyukovMpscRing[uint32], ThreadSignalPtr)] = @[]
        withLock(`globalLockIdent`):
          var i = 0
          while i < `globalBucketCountIdent`:
            if `globalBucketsIdent`[i].brokerCtx == ctx and
                `globalBucketsIdent`[i].threadId == myThreadId and
                `globalBucketsIdent`[i].threadGen == myThreadGen and
                `globalBucketsIdent`[i].active:
              ringsToShutdown.add(
                (
                  `globalBucketsIdent`[i].ring,
                  `globalBucketsIdent`[i].listenerSignal,
                )
              )
              for j in i ..< `globalBucketCountIdent` - 1:
                `globalBucketsIdent`[j] = `globalBucketsIdent`[j + 1]
              `globalBucketCountIdent` -= 1
            else:
              inc i

        var shutdownFuts: seq[Future[void]] = @[]
        var k = 0
        while k < `tvShutdownFutsIdent`.len:
          if `tvShutdownFutsIdent`[k][0] == ctx:
            shutdownFuts.add(`tvShutdownFutsIdent`[k][1])
            `tvShutdownFutsIdent`.del(k)
          else:
            inc k

        # Close each ring; the poll fn observes `closed && empty` and
        # self-unregisters via return-code 2 + completes shutdownFut.
        # Signal the dispatcher so the poll fn actually runs.
        for (ring, sig) in ringsToShutdown:
          ring.close()
          fireBrokerSignal(sig)

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

        # Grace window: an emit that captured ring pointers under lock
        # before we removed the bucket may still be mid-`tryEnqueue`.
        # The poll fn has already self-unregistered (return 2), and the
        # ring is closed, so any new tryEnqueue gets rejected — but we
        # need a brief delay before deallocShared so the in-flight
        # callers can complete their access. 50ms matches the original
        # `deferredFreeEventChan` window.
        try:
          await sleepAsync(chronos.milliseconds(50))
        except CatchableError:
          discard
        for (ring, _) in ringsToShutdown:
          freeVyukovMpscRing(ring)

  )

  # ── Public shutdown ───────────────────────────────────────────────────
  result.add(
    quote do:
      proc shutdown*(
          _: typedesc[`typeIdent`]
      ): Future[void] {.async: (raises: []).} =
        await `shutdownProcessLoopsForCtxIdent`(DefaultBrokerContext)

      proc shutdown*(
          _: typedesc[`typeIdent`], brokerCtx: BrokerContext
      ): Future[void] {.async: (raises: []).} =
        await `shutdownProcessLoopsForCtxIdent`(brokerCtx)

  )

  when defined(brokerDebug):
    echo result.repr
