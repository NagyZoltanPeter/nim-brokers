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
##     on the C heap under a `BrokerRingLease`; the bucket, its poll fn and
##     every in-flight cross-thread emit hold a reference, and the last one
##     to drop it frees the ring (no timed grace window).
##   - The global event slab is allocated lazily, by whichever thread
##     first calls `listen()` or `emit()`. That thread MUST outlive the
##     slab.
##   - Sender threads only ever touch atomics + memcpy + signal-fire —
##     never the Nim allocator on the hot path.

{.push raises: [].}

import std/[macros, strutils, locks, tables, atomics]
import chronos, chronicles
import results
import
  ./helper/broker_utils,
  ../broker_context,
  ../broker_scope,
  ./mt_broker_common,
  ./mt_queue,
  ./mt_transport,
  ./mt_codec,
  ./mt_config,
  ./broker_debug

export
  results, chronos, broker_context, broker_scope, chronicles, mt_broker_common,
  mt_transport, mt_config

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
    body: NimNode, cfgIn: MtEvtCfg = defaultMtEvtCfg()
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

  # Apply type-driven default for maxPayloadBytes when neither a kwarg
  # nor a preset set it. Warn if the type is unclassifiable so the user
  # knows to provide an explicit override. Void / zero-field bodies
  # collapse to the scalar bucket: a payload-less notification only
  # ships the CBOR envelope (a handful of bytes), and the conservative
  # 1 KB default would otherwise pin a full megabyte slab per event
  # type for no reason.
  var cfg = cfgIn
  if cfg.maxPayloadBytesOrigin == "default":
    if fieldTypes.len > 0:
      let cls = classifyFieldsMax(fieldTypes)
      cfg.maxPayloadBytes = cls.bytes
      cfg.maxPayloadBytesOrigin = "auto:" & cls.reason
      if cls.reason.startsWith("unclassifiable"):
        warning(
          "[brokers] EventBroker(" & typeDisplayName & ") could not auto-size payload (" &
            cls.reason & "); falling back to " & $cls.bytes &
            " B. Override with `maxPayloadBytes = N`."
        )
    else:
      cfg.maxPayloadBytes = ScalarBytes
      cfg.maxPayloadBytesOrigin = "auto:void"

  when not defined(brokerConfigSilent):
    hint(fmtEvtCfgSummary(typeDisplayName, cfg))

  # ── Identifier setup ──────────────────────────────────────────────────
  let handlerProcIdent = ident(typeDisplayName & "ListenerProc")
  let listenerHandleIdent = ident(typeDisplayName & "Listener")
  let exportedHandlerProcIdent = postfix(copyNimTree(handlerProcIdent), "*")
  let exportedListenerHandleIdent = postfix(copyNimTree(listenerHandleIdent), "*")

  let bucketName = ident(typeDisplayName & "MtEventBucket")

  let regIdent = ident("g" & typeDisplayName & "MtRegistry")

  let globalSlabIdent = ident("g" & typeDisplayName & "MtSlab")

  let initProcIdent = ident("ensureInit" & typeDisplayName & "MtBroker")
  let listenerTaskIdent = ident("notify" & typeDisplayName & "Listener")
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
  # Part D-3: optional companion hook fired by `dropAllListenersImpl`
  # after listener clearing completes. Used by the CBOR FFI library
  # (`api_library.nim`) to clear the foreign-subscriber registry +
  # reset the per-event atomic counter in lock-step with Nim-side
  # listener drops. Single slot per type — the only intended user is
  # the per-event installer registered at `_createContext` time.
  let dropAllHookProcTypeIdent = ident(typeDisplayName & "MtDropAllHook")
  let dropAllHookIdent = ident("g" & typeDisplayName & "MtDropAllHook")
  let dropAllHookLockIdent = ident("g" & typeDisplayName & "MtDropAllHookLock")
  let dropAllHookInitIdent = ident("g" & typeDisplayName & "MtDropAllHookInit")
  let setDropAllHookIdent = ident("setDropAll" & typeDisplayName & "Hook")
  let shutdownProcessLoopsForCtxIdent =
    ident("shutdownProcessLoopsForCtx" & typeDisplayName)

  let queueDepthLit = newLit(cfg.queueDepth)
  let slabCapacityLit = newLit(cfg.slabCapacity)
  let payloadBytesLit = newLit(cfg.maxPayloadBytes)
  let maxDynPayloadLit = newLit(cfg.maxDynamicPayloadBytes)
  let freeListShardsLit = newLit(uint32(cfg.freeListShards))

  result = newStmtList()

  # ── Type section ──────────────────────────────────────────────────────
  let brokerTypes = quote:
    type
      `exportedTypeIdent` = `objectDef`
      `exportedListenerHandleIdent` = object
        id*: uint64
        threadId*: pointer ## Thread that registered this listener.

      `exportedHandlerProcIdent` =
        proc(event: `typeIdent`): Future[void] {.async: (raises: []), gcsafe.}

      `dropAllHookProcTypeIdent` = proc(brokerCtx: BrokerContext) {.gcsafe, raises: [].}

      `bucketName` = object
        head: MtBucketHead ## lease = bucket + poll fn + in-flight emit refs

  # Attach the captured `##` doc text to the re-emitted event type (#50).
  attachFirstTypeDefDoc(brokerTypes, parsed.docText)
  result.add(brokerTypes)

  # ── Codec procs (marshal / unmarshal) ─────────────────────────────────
  for procNode in genMtCodecProcs(typeIdent):
    result.add(procNode)

  # ── Global shared state ───────────────────────────────────────────────
  result.add(
    quote do:
      var `regIdent`: MtRegistry[`bucketName`]
      var `globalSlabIdent`: MtLazySlab
        ## lazily allocated by the first listen() / emit() caller, whose
        ## thread must outlive it (never freed).
      # Part D-3 dropAllListeners hook. Single slot per event type;
      # `dropAllHookIdent` is `nil` when no hook is registered.
      var `dropAllHookIdent`: `dropAllHookProcTypeIdent`
      var `dropAllHookLockIdent`: Lock
      var `dropAllHookInitIdent`: Atomic[int]
        ## 0 = uninitialised, 1 = initialising, 2 = ready; gates the hook lock.
  )

  # ── Init helpers ──────────────────────────────────────────────────────
  result.add(
    quote do:
      proc `initProcIdent`() =
        `regIdent`.ensureInit()
        # Part D-3 dropAllListeners hook storage: same one-shot CAS-init
        # protocol, so concurrent callers see an initialised lock before any
        # reader / writer touches it.
        if `dropAllHookInitIdent`.load(moRelaxed) != 2:
          var hookExpected = 0
          if `dropAllHookInitIdent`.compareExchange(
            hookExpected, 1, moAcquire, moRelaxed
          ):
            initLock(`dropAllHookLockIdent`)
            `dropAllHookInitIdent`.store(2, moRelease)
          else:
            while `dropAllHookInitIdent`.load(moAcquire) != 2:
              discard
        `globalSlabIdent`.ensureInit(
          uint32(`slabCapacityLit`), uint32(`payloadBytesLit`), `freeListShardsLit`
        )

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

  # ── Poll fn maker ─────────────────────────────────────────────────────
  result.add(
    quote do:
      proc `pollFnMakerIdent`(
          ring: ptr VyukovMpscRing[uint32],
          lease: ptr BrokerRingLease,
          loopCtx: BrokerContext,
          shutdownFut: Future[void],
      ): ThreadDispatchPollFn =
        ## The poll fn owns one `lease` reference (taken by the caller) and
        ## drops it when it retires on a closed, drained ring.
        let capturedRing = ring
        let capturedLease = lease
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
                releaseLease(capturedLease)
                return 2
              return 0
            case cellIdx
            of CtrlClearListeners:
              `clearListenersIdent`(capturedCtx)
              return 1
            else:
              # Normal cell: decode, dispatch, decRef. dataPtr/dataLen resolve
              # the heap-spill buffer when the payload spilled, else the inline
              # cell region.
              var ev: `typeIdent`
              let payloadPtr = `globalSlabIdent`.slab.dataPtr(cellIdx)
              let payloadLen = `globalSlabIdent`.slab.dataLen(cellIdx)
              let ok =
                try:
                  mtUnmarshal(payloadPtr, payloadLen, ev)
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
                error "Failed to unmarshal event payload", eventType = `typeNameLit`
              releaseCellRef(`globalSlabIdent`.slab, cellIdx)
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
        var spawnRing: ptr VyukovMpscRing[uint32]
        var spawnLease: ptr BrokerRingLease
        `regIdent`.locked:
          if `regIdent`.setupCheck(brokerCtx, mspReuseOwned) == msoCreate:
            let ring = newVyukovMpscRing[uint32](`queueDepthLit`)
            # One reference for the bucket (dropped by shutdownProcessLoopsForCtx)
            # and one for the poll fn registered below.
            let lease = newBrokerRingLease(ring)
            acquireLease(lease)
            var head = initHead(brokerCtx, ring, lease)
            head.hasListeners = true
            `regIdent`.append(`bucketName`(head: head))
            spawnRing = ring
            spawnLease = lease

        if not spawnRing.isNil:
          let shutdownFut =
            newFuture[void]("eventBroker." & `typeNameLit` & ".shutdown")
          `tvShutdownFutsIdent`.add((brokerCtx, shutdownFut))
          registerBrokerPoller(
            `pollFnMakerIdent`(spawnRing, spawnLease, brokerCtx, shutdownFut)
          )
          ensureBrokerDispatchStarted()

        return ok(`listenerHandleIdent`(id: newId, threadId: currentMtThreadId()))

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
  # SYNC, for cross-lane shape parity with the single-thread EventBroker
  # (whose public `emit` is also void). emit never awaits listener completion
  # in any lane — same-thread listeners are asyncSpawn'd (fire-and-forget),
  # cross-thread cells are marshalled + enqueued synchronously here. Keeping
  # this a plain proc (not async) means the marshal/enqueue happens before
  # `emit` returns — no deferral vs the previous async-but-await-free shape.
  result.add(
    quote do:
      proc `emitImplIdent`(
          brokerCtx: BrokerContext, event: `typeIdent`
      ) {.gcsafe, raises: [].} =
        `initProcIdent`()

        when compiles(event.isNil()):
          if event.isNil():
            error "Cannot emit uninitialized event object", eventType = `typeNameLit`
            return

        type CrossTarget = object
          ring: ptr VyukovMpscRing[uint32]
          signal: ptr BrokerSignalShared
          lease: ptr BrokerRingLease

        var crossTargets: seq[CrossTarget] = @[]
        # Each target's lease is taken under the lock and held until its
        # enqueue + wake are done (every return path): the listener thread may
        # shut its bucket down meanwhile (BrokerRingLease).
        defer:
          for target in crossTargets:
            releaseLease(target.lease)
        var hasSameThread = false

        `regIdent`.locked:
          for i in 0 ..< `regIdent`.count:
            let head = `regIdent`.buckets[i].head
            if head.ctx == brokerCtx and head.active and head.hasListeners:
              if head.isOwnedHere():
                hasSameThread = true
              else:
                acquireLease(head.lease)
                crossTargets.add(
                  CrossTarget(ring: head.ring, signal: head.signal, lease: head.lease)
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

        # Cross-thread fan-out via one shared cell, refcounted per target.
        let c = claimCell(
          `globalSlabIdent`.slab, event, `maxDynPayloadLit`, refs = crossTargets.len
        )
        case c.status
        of mssOk:
          discard
        of mssSlabExhausted:
          warn "event dropped: slab exhausted",
            eventType = `typeNameLit`, targets = crossTargets.len
          return
        of mssTooLarge:
          error "event dropped: payload exceeds maxDynamicPayloadBytes",
            eventType = `typeNameLit`, needed = c.needed, cap = `maxDynPayloadLit`
          return
        of mssSpillFailed:
          error "event dropped: spill allocation failed",
            eventType = `typeNameLit`, needed = c.needed
          return
        of mssMarshalFailed, mssQueueFull:
          return

        for target in crossTargets:
          if not target.ring.tryEnqueue(c.idx):
            warn "event dropped: listener queue full", eventType = `typeNameLit`
            releaseCellRef(`globalSlabIdent`.slab, c.idx)
          else:
            fireBrokerSignal(target.signal)

  )

  # ── Public emit ───────────────────────────────────────────────────────
  # SYNC void, matching the single-thread EventBroker. See the emit-impl note.
  result.add(
    quote do:
      proc emit*(event: `typeIdent`) =
        `emitImplIdent`(DefaultBrokerContext, event)

      proc emit*(_: typedesc[`typeIdent`], event: `typeIdent`) =
        `emitImplIdent`(DefaultBrokerContext, event)

      proc emit*(
          _: typedesc[`typeIdent`], brokerCtx: BrokerContext, event: `typeIdent`
      ) =
        `emitImplIdent`(brokerCtx, event)

  )

  # ── Field-constructor emit overloads (for inline object types) ────────
  if hasInlineFields:
    let typedescParamType =
      newTree(nnkBracketExpr, ident("typedesc"), copyNimTree(typeIdent))

    # SYNC ctor-emit overloads (parity with single-thread + the void public
    # emit above): no async pragma, direct call to the sync emitImpl.
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
    let emitCtorBodyDefault = newStmtList(emitCtorCallDefault)

    let typedescEmitProcDefault = newTree(
      nnkProcDef,
      postfix(ident("emit"), "*"),
      newEmptyNode(),
      newEmptyNode(),
      emitCtorParams,
      newEmptyNode(),
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
    let emitCtorBodyCtx = newStmtList(emitCtorCallCtx)

    let typedescEmitProcCtx = newTree(
      nnkProcDef,
      postfix(ident("emit"), "*"),
      newEmptyNode(),
      newEmptyNode(),
      emitCtorParamsCtx,
      newEmptyNode(),
      newEmptyNode(),
      emitCtorBodyCtx,
    )
    result.add(typedescEmitProcCtx)

  # ── dropListener impl ─────────────────────────────────────────────────
  # ┌──────────────────────────────────────────────────────────────────┐
  # │ NO async / NO await in this impl body — keep it SUSPENSION-FREE.   │
  # │ The public dropListener/dropAllListeners overloads are async only  │
  # │ for cross-lane shape parity (single-thread is genuinely async).    │
  # │ chronos runs an await-free async body eagerly, which is what keeps │
  # │ FFI teardown + the Part D-3 dropAll hook correct even when the     │
  # │ returned Future is discarded/unpolled. Adding an await here        │
  # │ reintroduces the SubsRegistry-orphan regression.                   │
  # │ See doc/design/DROP_ASYNC_EMIT_SYNC_PLAN.md §Risks (R2).            │
  # └──────────────────────────────────────────────────────────────────┘
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

          `regIdent`.locked:
            let i = `regIdent`.findOwnedIdx(brokerCtx)
            if i >= 0:
              `regIdent`.buckets[i].head.hasListeners = false

  )

  # ── dropAllListeners impl ─────────────────────────────────────────────
  # Same-thread: clears tvHandlers immediately + flips flag under lock.
  # Cross-thread: flips flag + pushes a CtrlClearListeners sentinel into
  # the bucket's ring so the listener thread clears its tvHandlers on
  # the next poll cycle.
  # ┌──────────────────────────────────────────────────────────────────┐
  # │ NO async / NO await in this impl body — keep it SUSPENSION-FREE.   │
  # │ The public overload is async only for cross-lane shape parity.     │
  # │ The Part D-3 dropAll hook fires at the TAIL of this body; an await │
  # │ before it would defer the hook past return, so a discarded/        │
  # │ unawaited Future would never decrement subsCount → phantom         │
  # │ foreign-subscriber orphan bug. See DROP_ASYNC_EMIT_SYNC_PLAN §R2.  │
  # └──────────────────────────────────────────────────────────────────┘
  result.add(
    quote do:
      proc `dropAllListenersImplIdent`(brokerCtx: BrokerContext) =
        `initProcIdent`()

        var crossRings:
          seq[(ptr VyukovMpscRing[uint32], ptr BrokerSignalShared, ptr BrokerRingLease)] =
          @[]

        `regIdent`.locked:
          for i in 0 ..< `regIdent`.count:
            let head = `regIdent`.buckets[i].head
            if head.ctx == brokerCtx and head.hasListeners:
              `regIdent`.buckets[i].head.hasListeners = false
              # (threadId, threadGen): a reused threadvar address from a later
              # thread is not this thread.
              if not head.isOwnedHere():
                # Held until the sentinel is enqueued (BrokerRingLease).
                acquireLease(head.lease)
                crossRings.add((head.ring, head.signal, head.lease))

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
        for (ring, sig, lease) in crossRings:
          discard ring.tryEnqueue(CtrlClearListeners)
          fireBrokerSignal(sig)
          releaseLease(lease)

        # Part D-3: invoke the companion cleanup hook (if any) AFTER
        # listener clearing. The CBOR FFI library registers this hook
        # in its per-event installer to clear the foreign-subscriber
        # registry + reset the per-event atomic counter, keeping
        # `SubsRegistry` in lock-step with the MT EventBroker listener
        # table on dropAllListeners. The hook runs unlocked on the
        # caller's thread; it's the hook's responsibility to acquire
        # whatever locks its data structures need.
        var hookSnap: `dropAllHookProcTypeIdent` = nil
        {.cast(gcsafe).}:
          withLock(`dropAllHookLockIdent`):
            hookSnap = `dropAllHookIdent`
        if not hookSnap.isNil:
          hookSnap(brokerCtx)

  )

  # ── Public dropListener / dropAllListeners ────────────────────────────
  # Async for cross-lane shape parity with the single-thread EventBroker
  # (where drop genuinely awaits in-flight listener cancellation). The MT
  # impls above are suspension-free, so these complete eagerly on first
  # poll — the `await` is purely a uniform call-site contract. NOT
  # `{.discardable.}`: callers must `await`, identical to single-thread.
  result.add(
    quote do:
      proc dropListener*(
          _: typedesc[`typeIdent`], handle: `listenerHandleIdent`
      ): Future[void] {.async: (raises: []).} =
        `dropListenerImplIdent`(DefaultBrokerContext, handle)

      proc dropListener*(
          _: typedesc[`typeIdent`],
          brokerCtx: BrokerContext,
          handle: `listenerHandleIdent`,
      ): Future[void] {.async: (raises: []).} =
        `dropListenerImplIdent`(brokerCtx, handle)

      proc dropAllListeners*(
          _: typedesc[`typeIdent`]
      ): Future[void] {.async: (raises: []).} =
        `dropAllListenersImplIdent`(DefaultBrokerContext)

      proc dropAllListeners*(
          _: typedesc[`typeIdent`], brokerCtx: BrokerContext
      ): Future[void] {.async: (raises: []).} =
        `dropAllListenersImplIdent`(brokerCtx)

      proc `setDropAllHookIdent`*(
          _: typedesc[`typeIdent`], hook: `dropAllHookProcTypeIdent`
      ) =
        ## Part D-3: register a companion cleanup hook fired by
        ## `dropAllListeners` (any overload) AFTER listener clearing
        ## completes. Passing `nil` clears the slot. Single slot per
        ## event type — the intended sole caller is the CBOR FFI
        ## library's per-event installer.
        `initProcIdent`()
        {.cast(gcsafe).}:
          withLock(`dropAllHookLockIdent`):
            `dropAllHookIdent` = hook

  )

  # ── BrokerScope: release + scope overload ─────────────────────────────
  # Listeners live in this thread's threadvar table, so identity is checked
  # there: the handle's id must still map to the closure the scope installed
  # (ids restart once a ctx's table empties). The drop itself is the existing
  # suspension-free impl.
  let releaseListenerIdent = ident("release" & typeDisplayName & "Listener")
  result.add(
    quote do:
      proc `releaseListenerIdent`(
          brokerCtx: BrokerContext,
          handle: `listenerHandleIdent`,
          handler: `handlerProcIdent`,
      ): Future[BrokerReleaseOutcome] {.async: (raises: []).} =
        if handle.threadId != currentMtThreadId():
          return broOwnerChanged
        for i in 0 ..< `tvListenerCtxIdent`.len:
          if `tvListenerCtxIdent`[i] == brokerCtx:
            let current = `tvListenerHandlersIdent`[i].getOrDefault(handle.id)
            if current.isNil():
              return broAlreadyGone
            if current != handler:
              return broTakenOver
            `dropListenerImplIdent`(brokerCtx, handle)
            return broReleased
        broAlreadyGone

      proc listen*(
          _: typedesc[`typeIdent`], scope: BrokerScope, handler: `handlerProcIdent`
      ): Result[`listenerHandleIdent`, string] =
        if not scope.onOwningThread("listen"):
          return err("BrokerScope used off its owning thread")
        if not scope.isOpen:
          return err("BrokerScope is closing")
        let brokerCtx = scope.ctx
        let handle = ?`listenImplIdent`(brokerCtx, handler)
        scope.track(
          proc() {.async: (raises: []), gcsafe.} =
            reportBrokerRelease(
              await `releaseListenerIdent`(brokerCtx, handle, handler),
              `typeNameLit`,
              "listener",
              brokerCtx,
            )
        )
        ok(handle)

  )

  # ── shutdownProcessLoopsForCtx (internal; used by API teardown) ───────
  # Must run on the bucket-owning thread. Drains the bucket's ring,
  # decRefs remaining cells, removes the bucket from the registry, and drops
  # the bucket's ring lease (the last holder frees the ring).
  result.add(
    quote do:
      proc `shutdownProcessLoopsForCtxIdent`(
          ctx: BrokerContext
      ) {.async: (raises: []).} =
        var ringsToShutdown:
          seq[(ptr VyukovMpscRing[uint32], ptr BrokerSignalShared, ptr BrokerRingLease)] =
          @[]
        `regIdent`.locked:
          var i = 0
          while i < `regIdent`.count:
            let head = `regIdent`.buckets[i].head
            if head.ctx == ctx and head.isOwnedHere() and head.active:
              ringsToShutdown.add((head.ring, head.signal, head.lease))
              `regIdent`.removeAt(i)
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
        for (ring, sig, _) in ringsToShutdown:
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

        # Drop the bucket's reference. An emit that found the bucket before it
        # was removed holds its own, as does the poll fn until it retires, so
        # whichever finishes last frees the ring — no timed grace window.
        for (_, _, lease) in ringsToShutdown:
          releaseLease(lease)

  )

  # ── Public shutdown ───────────────────────────────────────────────────
  result.add(
    quote do:
      proc shutdown*(_: typedesc[`typeIdent`]): Future[void] {.async: (raises: []).} =
        await `shutdownProcessLoopsForCtxIdent`(DefaultBrokerContext)

      proc shutdown*(
          _: typedesc[`typeIdent`], brokerCtx: BrokerContext
      ): Future[void] {.async: (raises: []).} =
        await `shutdownProcessLoopsForCtxIdent`(brokerCtx)

  )

  # ── bind listener sugar (issue #42) ───────────────────────────────
  # `bindListener` = sugar for `listen`. The MT listener proc type always takes
  # the event value (`proc(event: T): Future[void] {.async: (raises: []),
  # gcsafe.}`), so the trampoline forwards it unconditionally.
  block:
    let listenerProcTy = quote:
      proc(event: `typeIdent`): Future[void] {.async: (raises: []), gcsafe.}
    let slot = BindSlot(
      params:
        @[newTree(nnkIdentDefs, ident("event"), copyNimTree(typeIdent), newEmptyNode())],
      returnType: futureVoidTy(),
      pragma: procTyPragma(listenerProcTy),
    )
    result.add(
      buildBindTemplates(typeIdent, "listen", "bindListener", @[slot], awaitCall = true)
    )

    # ── listenIt body sugar (issue #46, per-type since #51) ─────────
    # Same shape as the single-thread lane; `isVoid = false` because the MT
    # listener proc type always carries the event value.
    result.add(
      buildItSugarTemplates(
        typeIdent,
        "listen",
        "listenIt",
        "brokerEvent",
        futureVoidTy(),
        procTyPragma(listenerProcTy),
        isVoid = false,
      )
    )

  when defined(brokerDebug):
    writeBrokerDebug("EventBrokerMt", typeDisplayName, result)
    when defined(brokerDebugStdout):
      echo result.repr
