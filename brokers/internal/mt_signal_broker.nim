## Multi-Thread SignalBroker
## -------------------------
## Generates a multi-thread capable SignalBroker: a single handler registered
## on one thread (via `onSignal`), with `signal(...)` callable from any thread.
## Fire-and-forget — there is no reply path — but `signal` returns
## `Result[void, string]` so the caller learns whether the payload was
## *accepted* (a handler exists + the queue had room), never whether it ran.
##
## Same-thread signal→handler dispatch bypasses the ring and is delivered
## directly via `asyncSpawn`. Cross-thread delivery marshals the payload into a
## global refcounted slab cell and enqueues its index on the handler thread's
## Vyukov MPSC ring, then fires that thread's dispatch signal — identical
## machinery to the multi-thread EventBroker, minus the fan-out (a signal has
## exactly one target bucket per context).
##
## Structurally this is EventBroker(mt)'s fire-and-forget transport fused with
## RequestBroker(mt)'s single-registry ownership model:
##   - one bucket per (brokerCtx) — `onSignal` rejects a duplicate;
##   - the bucket-owning thread (the one that ran `onSignal`) allocates the
##     ring and, on `dropSignalHandler`, closes it; the poll fn hands the
##     ring's lease to the per-thread pending registry and `teardownBrokerThread`
##     drops the owner reference — an in-flight cross-thread `signal()` holds
##     its own reference, so the last holder frees the ring (BrokerRingLease);
##   - the global payload slab is allocated lazily by the first
##     onSignal/signal caller, whose thread must outlive it (never freed,
##     like the EventBroker global slab).
##
## Lock-free caller fast-fail: a per-type `Atomic[int]` handler-present counter
## is bumped by `onSignal` / `dropSignalHandler`; `signal()` reads it with an
## acquire load and returns `"no signal handler installed"` with no lock taken
## when it is zero (no handler exists anywhere). A non-zero counter falls
## through to the locked bucket resolve, which pins the specific context.
## (The threadvar bucket-pointer cache described in the design is a further
## optimization deferred to a follow-up; correctness does not depend on it and
## the per-signal lock matches the shipped EventBroker(mt) emit path.)

{.push raises: [].}

import std/[macros, strutils, locks, atomics, options]
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
  mt_transport, mt_config, options

# ---------------------------------------------------------------------------
# Macro code generator
# ---------------------------------------------------------------------------

proc generateMtSignalBroker*(
    body: NimNode, cfgIn: MtSigCfg = defaultMtSigCfg()
): NimNode =
  when defined(brokerDebug):
    echo body.treeRepr
    echo "SignalBroker mode: mt"

  let parsed = parseSingleTypeDef(body, "SignalBroker", collectFieldInfo = true)
  let typeIdent = parsed.typeIdent
  let objectDef = parsed.objectDef
  let fieldNames = parsed.fieldNames
  let fieldTypes = parsed.fieldTypes
  let hasInlineFields = parsed.hasInlineFields
  let isVoid = parsed.isVoid

  let exportedTypeIdent = postfix(copyNimTree(typeIdent), "*")
  let typeDisplayName = sanitizeIdentName(typeIdent)
  let typeNameLit = newLit(typeDisplayName)

  # Type-driven default for maxPayloadBytes (same policy as EventBroker(mt)):
  # a payload-less pulse or a scalar field collapses to the scalar bucket.
  var cfg = cfgIn
  if cfg.maxPayloadBytesOrigin == "default":
    if fieldTypes.len > 0:
      let cls = classifyFieldsMax(fieldTypes)
      cfg.maxPayloadBytes = cls.bytes
      cfg.maxPayloadBytesOrigin = "auto:" & cls.reason
      if cls.reason.startsWith("unclassifiable"):
        warning(
          "[brokers] SignalBroker(" & typeDisplayName & ") could not auto-size payload (" &
            cls.reason & "); falling back to " & $cls.bytes &
            " B. Override with `maxPayloadBytes = N`."
        )
    else:
      cfg.maxPayloadBytes = ScalarBytes
      cfg.maxPayloadBytesOrigin = "auto:void"

  when not defined(brokerConfigSilent):
    hint(fmtSigCfgSummary(typeDisplayName, cfg))

  # ── Identifier setup ──────────────────────────────────────────────────
  let handlerProcIdent = ident(typeDisplayName & "SignalHandler")
  let exportedHandlerProcIdent = postfix(copyNimTree(handlerProcIdent), "*")
  let bucketName = ident(typeDisplayName & "MtSignalBucket")

  let regIdent = ident("g" & typeDisplayName & "MtSigRegistry")
  let globalSlabIdent = ident("g" & typeDisplayName & "MtSigSlab")
  let presentIdent = ident("g" & typeDisplayName & "MtSigPresent")

  let initProcIdent = ident("ensureInit" & typeDisplayName & "MtSigBroker")
  let signalTaskIdent = ident("notify" & typeDisplayName & "Signal")
  let pollFnMakerIdent = ident("makePollFn" & typeDisplayName & "Sig")

  let tvCtxIdent = ident("g" & typeDisplayName & "TvSigCtxs")
  let tvHandlerIdent = ident("g" & typeDisplayName & "TvSigHandlers")
  let tvFutsIdent = ident("g" & typeDisplayName & "TvSigFuts")

  let onSignalImplIdent = ident("onSignal" & typeDisplayName & "MtImpl")
  let signalImplIdent = ident("signal" & typeDisplayName & "MtImpl")
  let dropImplIdent = ident("drop" & typeDisplayName & "MtImpl")
  let setupBucketIdent = ident("setupBucket" & typeDisplayName & "Sig")
  let findHandlerIdent = ident("findTvHandler" & typeDisplayName & "Sig")

  let queueDepthLit = newLit(cfg.queueDepth)
  let slabCapacityLit = newLit(cfg.slabCapacity)
  let payloadBytesLit = newLit(cfg.maxPayloadBytes)
  let maxDynPayloadLit = newLit(cfg.maxDynamicPayloadBytes)
  let freeListShardsLit = newLit(uint32(cfg.freeListShards))

  result = newStmtList()

  # ── Type section ──────────────────────────────────────────────────────
  let handlerProcTy =
    if isVoid:
      quote:
        proc(): Future[void] {.async: (raises: []), gcsafe.}
    else:
      quote:
        proc(signalValue: `typeIdent`): Future[void] {.async: (raises: []), gcsafe.}

  let brokerTypes = quote:
    type
      `exportedTypeIdent` = `objectDef`
      `exportedHandlerProcIdent` = `handlerProcTy`
      `bucketName` = object
        head: MtBucketHead ## lease = owner + in-flight signal() refs

  # Attach the captured `##` doc text to the re-emitted signal type (#50).
  attachFirstTypeDefDoc(brokerTypes, parsed.docText)
  result.add(brokerTypes)

  # ── Codec procs (marshal / unmarshal / size of the payload value) ─────
  for procNode in genMtCodecProcs(typeIdent):
    result.add(procNode)

  # ── Global shared state ───────────────────────────────────────────────
  result.add(
    quote do:
      var `regIdent`: MtRegistry[`bucketName`]
      var `globalSlabIdent`: MtLazySlab
      var `presentIdent`: Atomic[int]
        ## handler-present counter (# of installed handlers across all ctxs).
        ## `signal()` acquire-loads it; zero → fast-fail with no lock taken.
  )

  # ── Init helpers ──────────────────────────────────────────────────────
  result.add(
    quote do:
      proc `initProcIdent`() =
        `regIdent`.ensureInit()
        `globalSlabIdent`.ensureInit(
          uint32(`slabCapacityLit`), uint32(`payloadBytesLit`), `freeListShardsLit`
        )

  )

  # ── Threadvar handler storage (owning thread) ─────────────────────────
  result.add(
    quote do:
      var `tvCtxIdent` {.threadvar.}: seq[BrokerContext]
      var `tvHandlerIdent` {.threadvar.}: seq[`handlerProcIdent`]
      var `tvFutsIdent` {.threadvar.}: seq[(BrokerContext, Future[void])]

      proc `findHandlerIdent`(brokerCtx: BrokerContext): `handlerProcIdent` =
        for i in 0 ..< `tvCtxIdent`.len:
          if `tvCtxIdent`[i] == brokerCtx:
            return `tvHandlerIdent`[i]
        default(`handlerProcIdent`)

  )

  # ── Dispatch task: swallow handler exceptions with a chronicles warn ──
  # Always takes the payload value so the same-thread and cross-thread dispatch
  # call sites stay uniform; the void form simply ignores it (its handler takes
  # no arg). `signalValue` is the wire value in both cases (a default-
  # constructed empty object for the void pulse). The `when` selects the arity
  # at generation time; the dead branch is parsed but never sem-checked.
  let isVoidLit = newLit(isVoid)
  result.add(
    quote do:
      proc `signalTaskIdent`(
          callback: `handlerProcIdent`, signalValue: `typeIdent`
      ): Future[void] {.async: (raises: []).} =
        if callback.isNil():
          return
        try:
          when `isVoidLit`:
            await callback()
          else:
            await callback(signalValue)
        except CatchableError:
          warn "SignalBroker handler raised",
            signalType = `typeNameLit`, error = getCurrentExceptionMsg()

  )

  # ── Poll fn maker (handler-thread side) ───────────────────────────────
  result.add(
    quote do:
      proc `pollFnMakerIdent`(
          ring: ptr VyukovMpscRing[uint32],
          lease: ptr BrokerRingLease,
          loopCtx: BrokerContext,
      ): ThreadDispatchPollFn =
        let capturedRing = ring
        let capturedLease = lease
        let capturedCtx = loopCtx
        return proc(): int {.gcsafe, raises: [].} =
          {.cast(gcsafe).}:
            var cellIdx: uint32
            if not capturedRing.tryDequeue(cellIdx):
              if capturedRing.isClosed():
                # Owner reference dropped at thread exit (global slab, no pool).
                enqueuePendingRingFree(capturedLease)
                return 2
              return 0
            var ev: `typeIdent`
            let payloadPtr = `globalSlabIdent`.slab.dataPtr(cellIdx)
            let payloadLen = `globalSlabIdent`.slab.dataLen(cellIdx)
            let ok =
              try:
                mtUnmarshal(payloadPtr, payloadLen, ev)
              except Exception:
                false
            if ok:
              let handler = `findHandlerIdent`(capturedCtx)
              if not handler.isNil:
                let fut: Future[void] = `signalTaskIdent`(handler, ev)
                `tvFutsIdent`.add((capturedCtx, fut))
                asyncSpawn fut
            else:
              error "Failed to unmarshal signal payload", signalType = `typeNameLit`
            releaseCellRef(`globalSlabIdent`.slab, cellIdx)
            return 1

  )

  # ── owned-bucket cleanup at thread exit (forward decl) ────────────────
  # Defined after dropImpl; registered with the thread's teardown by
  # setupBucket so a handler thread that exits without dropping still retires
  # its handlers (owner-only drop, MT_OWNER_ONLY_CLEAR_PLAN).
  let autoClearIdent = ident("dropOwnedHandlers" & typeDisplayName & "Sig")
  result.add(
    quote do:
      proc `autoClearIdent`(): int {.nimcall, gcsafe, raises: [].}
  )

  # ── setupBucket (owning thread; allocates ring, registers poller) ─────
  result.add(
    quote do:
      proc `setupBucketIdent`(
          brokerCtx: BrokerContext
      ): Result[ptr VyukovMpscRing[uint32], string] =
        var ring: ptr VyukovMpscRing[uint32]
        var lease: ptr BrokerRingLease
        `regIdent`.locked:
          if `regIdent`.setupCheck(brokerCtx, mspRejectActive) == msoRejected:
            return err("SignalBroker(" & `typeNameLit` & "): handler already set")
          ring = newVyukovMpscRing[uint32](`queueDepthLit`)
          lease = newBrokerRingLease(ring)
          `regIdent`.append(`bucketName`(head: initHead(brokerCtx, ring, lease)))
        registerBrokerPoller(`pollFnMakerIdent`(ring, lease, brokerCtx))
        registerBrokerThreadCleanup(`autoClearIdent`)
        ensureBrokerDispatchStarted()
        ok(ring)

  )

  # ── onSignal impl ─────────────────────────────────────────────────────
  result.add(
    quote do:
      proc `onSignalImplIdent`(
          brokerCtx: BrokerContext, handler: `handlerProcIdent`
      ): Result[void, string] =
        if handler.isNil():
          return err("SignalBroker(" & `typeNameLit` & "): handler must be non-nil")
        `initProcIdent`()
        let r = `setupBucketIdent`(brokerCtx)
        if r.isErr():
          return err(r.error)
        `tvCtxIdent`.add(brokerCtx)
        `tvHandlerIdent`.add(handler)
        discard `presentIdent`.fetchAdd(1, moRelease)
        ok()

  )

  # ── signal impl (accept-and-dispatch; caller's thread) ────────────────
  # Always carries a payload value on the wire; the void form passes an empty
  # `default(T)` and the dispatch drops it (handler takes no arg).
  result.add(
    quote do:
      proc `signalImplIdent`(
          brokerCtx: BrokerContext, signalValue: `typeIdent`
      ): Result[void, string] {.gcsafe.} =
        # Lock-free fast-fail: no handler installed anywhere.
        if `presentIdent`.load(moAcquire) == 0:
          return err("no signal handler installed")
        `initProcIdent`()

        # The lease is taken with the bucket under the lock and held until the
        # enqueue + wake are done: the owner may drop the handler meanwhile
        # (BrokerRingLease).
        var target = `regIdent`.snapshot(brokerCtx, requireActive = true)
        defer:
          target.release()
        if not target.found:
          return err("no signal handler installed")

        # Same-thread fast path: bypass the ring, dispatch directly.
        if target.sameThread:
          let handler = `findHandlerIdent`(brokerCtx)
          if handler.isNil:
            return err("no signal handler installed")
          {.cast(gcsafe).}:
            let fut: Future[void] = `signalTaskIdent`(handler, signalValue)
            `tvFutsIdent`.add((brokerCtx, fut))
            asyncSpawn fut
          return ok()

        # Cross-thread: marshal payload into a refcounted global slab cell,
        # enqueue its index on the handler thread's ring, wake that thread.
        case sendCell(
          `globalSlabIdent`.slab, target.bucket.head.ring, target.bucket.head.signal,
          signalValue, `maxDynPayloadLit`,
        )
        of mssOk:
          ok()
        of mssSlabExhausted, mssQueueFull:
          err("queue full")
        of mssTooLarge:
          err(
            "SignalBroker(" & `typeNameLit` & "): payload exceeds maxDynamicPayloadBytes"
          )
        of mssSpillFailed:
          err("SignalBroker(" & `typeNameLit` & "): spill allocation failed")
        of mssMarshalFailed:
          err("SignalBroker(" & `typeNameLit` & "): payload marshal failed")

  )

  # ── dropSignalHandler impl (suspension-free; mirrors clearProvider) ───
  # NO async / NO await — the public overload is async only for cross-lane
  # shape parity. Removes the bucket, closes the ring (poll fn hands its lease to
  # the per-thread pending registry; owner ref dropped at teardownBrokerThread), cleans
  # the owning thread's threadvar, and decrements the handler-present counter.
  result.add(
    quote do:
      proc `dropImplIdent`(
          brokerCtx: BrokerContext, requireOwner = false
      ): BrokerReleaseOutcome {.gcsafe, discardable.} =
        ## Owner-only: the bucket is removed only when this thread owns it,
        ## decided in the same critical section as the removal so no other
        ## thread can drop + re-register in between. A non-owner gets
        ## `broOwnerChanged`. `requireOwner` only says the caller expects that
        ## outcome (BrokerScope release); otherwise a foreign call is logged.
        `initProcIdent`()
        var ring: ptr VyukovMpscRing[uint32]
        var handlerSig: ptr BrokerSignalShared
        var foreignOwned = false
        var found = false
        `regIdent`.locked:
          let i = `regIdent`.findIdx(brokerCtx, requireActive = true)
          if i >= 0:
            found = true
            # Owner-only: the handler closure lives in its owner's
            # threadvars, so only the owner can retire it consistently.
            if not `regIdent`.buckets[i].head.isOwnedHere():
              foreignOwned = true
            else:
              ring = `regIdent`.buckets[i].head.ring
              handlerSig = `regIdent`.buckets[i].head.signal
              `regIdent`.removeAt(i)

        if foreignOwned:
          if not requireOwner:
            error "dropSignalHandler ignored: called from a thread that does not own the handler",
              signalType = `typeNameLit`, brokerCtx = uint32(brokerCtx)
          return broOwnerChanged

        if not found:
          return broAlreadyGone
        result = broReleased

        {.cast(gcsafe).}:
          for i in countdown(`tvCtxIdent`.len - 1, 0):
            if `tvCtxIdent`[i] == brokerCtx:
              `tvCtxIdent`.del(i)
              `tvHandlerIdent`.del(i)
              break
        discard `presentIdent`.fetchSub(1, moRelease)
        if not ring.isNil:
          ring.close()
          fireBrokerSignal(handlerSig)

  )

  result.add(
    quote do:
      proc `autoClearIdent`(): int {.nimcall, gcsafe, raises: [].} =
        let owned = `regIdent`.ownedCtxs(requireActive = true)
        for ownedCtx in owned:
          `dropImplIdent`(ownedCtx)
        owned.len

  )

  # ── Public onSignal ───────────────────────────────────────────────────
  result.add(
    quote do:
      proc onSignal*(
          _: typedesc[`typeIdent`], handler: `handlerProcIdent`
      ): Result[void, string] =
        `onSignalImplIdent`(DefaultBrokerContext, handler)

      proc onSignal*(
          _: typedesc[`typeIdent`],
          brokerCtx: BrokerContext,
          handler: `handlerProcIdent`,
      ): Result[void, string] =
        `onSignalImplIdent`(brokerCtx, handler)

  )

  # ── Public signal ─────────────────────────────────────────────────────
  if isVoid:
    result.add(
      quote do:
        proc signal*(
            _: typedesc[`typeIdent`], brokerCtx: BrokerContext
        ): Result[void, string] =
          `signalImplIdent`(brokerCtx, `typeIdent`())

        proc signal*(_: typedesc[`typeIdent`]): Result[void, string] =
          `signalImplIdent`(DefaultBrokerContext, `typeIdent`())

    )
  else:
    result.add(
      quote do:
        proc signal*(
            _: typedesc[`typeIdent`], brokerCtx: BrokerContext, signalValue: `typeIdent`
        ): Result[void, string] =
          `signalImplIdent`(brokerCtx, signalValue)

        proc signal*(
            _: typedesc[`typeIdent`], signalValue: `typeIdent`
        ): Result[void, string] =
          `signalImplIdent`(DefaultBrokerContext, signalValue)

        proc signal*(signalValue: `typeIdent`): Result[void, string] =
          `signalImplIdent`(DefaultBrokerContext, signalValue)

    )

  # ── Field-constructor signal overloads (inline object types) ──────────
  if hasInlineFields:
    let typedescParamType =
      newTree(nnkBracketExpr, ident("typedesc"), copyNimTree(typeIdent))
    let resultTy = quote:
      Result[void, string]

    var emitCtorExpr = newTree(nnkObjConstr, copyNimTree(typeIdent))
    for i in 0 ..< fieldNames.len:
      emitCtorExpr.add(
        newTree(
          nnkExprColonExpr, copyNimTree(fieldNames[i]), copyNimTree(fieldNames[i])
        )
      )

    block:
      var params = newTree(nnkFormalParams, copyNimTree(resultTy))
      params.add(newTree(nnkIdentDefs, ident("_"), typedescParamType, newEmptyNode()))
      for i in 0 ..< fieldNames.len:
        params.add(
          newTree(
            nnkIdentDefs,
            copyNimTree(fieldNames[i]),
            copyNimTree(fieldTypes[i]),
            newEmptyNode(),
          )
        )
      let callDefault = newCall(
        copyNimTree(signalImplIdent),
        ident("DefaultBrokerContext"),
        copyNimTree(emitCtorExpr),
      )
      result.add(
        newTree(
          nnkProcDef,
          postfix(ident("signal"), "*"),
          newEmptyNode(),
          newEmptyNode(),
          params,
          newEmptyNode(),
          newEmptyNode(),
          newStmtList(callDefault),
        )
      )

    block:
      var params = newTree(nnkFormalParams, copyNimTree(resultTy))
      params.add(newTree(nnkIdentDefs, ident("_"), typedescParamType, newEmptyNode()))
      params.add(
        newTree(
          nnkIdentDefs, ident("brokerCtx"), ident("BrokerContext"), newEmptyNode()
        )
      )
      for i in 0 ..< fieldNames.len:
        params.add(
          newTree(
            nnkIdentDefs,
            copyNimTree(fieldNames[i]),
            copyNimTree(fieldTypes[i]),
            newEmptyNode(),
          )
        )
      let callCtx = newCall(
        copyNimTree(signalImplIdent), ident("brokerCtx"), copyNimTree(emitCtorExpr)
      )
      result.add(
        newTree(
          nnkProcDef,
          postfix(ident("signal"), "*"),
          newEmptyNode(),
          newEmptyNode(),
          params,
          newEmptyNode(),
          newEmptyNode(),
          newStmtList(callCtx),
        )
      )

  # ── dropSignalHandler / hasSignalHandler ──────────────────────────────
  # Public drop is async for cross-lane parity; the impl is suspension-free so
  # a discarded Future still clears eagerly (same contract as dropListener).
  result.add(
    quote do:
      proc dropSignalHandler*(
          _: typedesc[`typeIdent`], brokerCtx: BrokerContext
      ): Future[void] {.async: (raises: []).} =
        discard `dropImplIdent`(brokerCtx)

      proc dropSignalHandler*(
          _: typedesc[`typeIdent`]
      ): Future[void] {.async: (raises: []).} =
        discard `dropImplIdent`(DefaultBrokerContext)

      proc hasSignalHandler*(_: typedesc[`typeIdent`], brokerCtx: BrokerContext): bool =
        `initProcIdent`()
        `regIdent`.hasBucket(brokerCtx, requireActive = true)

      proc hasSignalHandler*(_: typedesc[`typeIdent`]): bool =
        hasSignalHandler(`typeIdent`, DefaultBrokerContext)

      proc signalHandlerPresent*(_: typedesc[`typeIdent`]): bool {.gcsafe.} =
        ## Lock-free acquire-load of the handler-present counter — safe to call
        ## from any thread (used by the FFI `<lib>_call` slot-free signal path to
        ## fast-fail with ProviderErr before the cross-thread hop). Coarse: true
        ## means a handler exists for *some* context (the FFI lane installs a
        ## single handler on the processing thread, so this is exact there).
        `presentIdent`.load(moAcquire) != 0

  )

  # ── Mock/replace trio (owning thread only) ────────────────────────────
  # Reads/writes the per-thread threadvar handler slot, so it MUST run on the
  # thread that installed the handler. `replaceSignalHandler` swaps only the
  # local closure — the bucket/ring/present-counter are untouched (no window
  # where `signal()` errs), ideal for feature toggles. Replace-with-`default`
  # does NOT tear the bucket down; use `dropSignalHandler` to fully remove.
  result.add(
    quote do:
      proc getCurrentSignalHandler*(
          _: typedesc[`typeIdent`], brokerCtx: BrokerContext
      ): Option[`handlerProcIdent`] =
        let h = `findHandlerIdent`(brokerCtx)
        if h.isNil:
          none(`handlerProcIdent`)
        else:
          some(h)

      proc replaceSignalHandler*(
          _: typedesc[`typeIdent`],
          brokerCtx: BrokerContext,
          handler: `handlerProcIdent`,
      ): Result[void, string] =
        ## Owning-thread only. Replace-or-insert the local closure; a new ctx
        ## also sets up its bucket + bumps the present counter.
        `initProcIdent`()
        for i in 0 ..< `tvCtxIdent`.len:
          if `tvCtxIdent`[i] == brokerCtx:
            `tvHandlerIdent`[i] = handler
            return ok()
        let r = `setupBucketIdent`(brokerCtx)
        if r.isErr():
          return err(r.error)
        `tvCtxIdent`.add(brokerCtx)
        `tvHandlerIdent`.add(handler)
        discard `presentIdent`.fetchAdd(1, moRelease)
        ok()

      template withMockSignalHandler*(
          t: typedesc[`typeIdent`],
          brokerCtx: BrokerContext,
          mock: `handlerProcIdent`,
          body: untyped,
      ): untyped =
        ## Owning-thread only. Install `mock` for the duration of `body`, then
        ## restore the captured handler (or drop it if none was set).
        let savedMockSignalHandler = getCurrentSignalHandler(t, brokerCtx)
        let mockInstalled = replaceSignalHandler(t, brokerCtx, mock)
        if mockInstalled.isErr():
          # Not `doAssert`: under --mm:orc a failing doAssert leaks its message
          # temporary (the noreturn assert path skips its destructor), and this
          # misuse path is exercised on purpose by test_mt_owner_only_clear.
          raise newException(
            AssertionDefect,
            "withMockSignalHandler: " & mockInstalled.error &
              " (only the handler's owning thread may mock it)",
          )
        try:
          body
        finally:
          if savedMockSignalHandler.isSome:
            discard replaceSignalHandler(t, brokerCtx, savedMockSignalHandler.get)
          else:
            discard dropSignalHandler(t, brokerCtx)

  )

  # ── BrokerScope: release + scope overloads ────────────────────────────
  # Emitted before the bind / `It` sugar templates, which bind the verb
  # overload set at their definition site. The release checks closure
  # identity in this thread's threadvar, then drops with `requireOwner` so the
  # bucket-ownership check and the removal share one lock section. Drops are
  # owner-only, so another thread cannot retire our bucket; if it is gone or
  # owned elsewhere anyway, purge the entry locally and leave the shared
  # registry alone.
  let releaseHandlerIdent = ident("release" & typeDisplayName & "SignalHandler")
  result.add(
    quote do:
      proc `releaseHandlerIdent`(
          brokerCtx: BrokerContext, handler: `handlerProcIdent`
      ): Future[BrokerReleaseOutcome] {.async: (raises: []).} =
        let current = `findHandlerIdent`(brokerCtx)
        if current.isNil():
          return broAlreadyGone
        if current != handler:
          return broTakenOver
        let outcome = `dropImplIdent`(brokerCtx, requireOwner = true)
        if outcome != broReleased:
          for i in countdown(`tvCtxIdent`.len - 1, 0):
            if `tvCtxIdent`[i] == brokerCtx:
              `tvCtxIdent`.del(i)
              `tvHandlerIdent`.del(i)
              break
        outcome

      proc onSignal*(
          _: typedesc[`typeIdent`], scope: BrokerScope, handler: `handlerProcIdent`
      ): Result[void, string] =
        if not scope.onOwningThread("onSignal"):
          return err("BrokerScope used off its owning thread")
        if not scope.isOpen:
          return err("BrokerScope is closing")
        let brokerCtx = scope.ctx
        ?`onSignalImplIdent`(brokerCtx, handler)
        scope.track(
          proc() {.async: (raises: []), gcsafe.} =
            reportBrokerRelease(
              await `releaseHandlerIdent`(brokerCtx, handler),
              `typeNameLit`,
              "signalHandler",
              brokerCtx,
            )
        )
        ok()

      proc replaceSignalHandler*(
          _: typedesc[`typeIdent`], scope: BrokerScope, handler: `handlerProcIdent`
      ): Result[void, string] =
        if not scope.onOwningThread("replaceSignalHandler"):
          return err("BrokerScope used off its owning thread")
        if not scope.isOpen:
          return err("BrokerScope is closing")
        let brokerCtx = scope.ctx
        ?replaceSignalHandler(`typeIdent`, brokerCtx, handler)
        scope.track(
          proc() {.async: (raises: []), gcsafe.} =
            reportBrokerRelease(
              await `releaseHandlerIdent`(brokerCtx, handler),
              `typeNameLit`,
              "signalHandler",
              brokerCtx,
            )
        )
        ok()

  )

  # ── bind / rebind signal-handler sugar (issue #42) ────────────────
  # `bindSignalHandler` = sugar for `onSignal`, `rebindSignalHandler` = sugar for
  # `replaceSignalHandler` (owning-thread only, same as the verbs they wrap).
  block:
    var slot = BindSlot(returnType: futureVoidTy(), pragma: procTyPragma(handlerProcTy))
    if isVoid:
      slot.params = @[]
    else:
      slot.params = @[
        newTree(
          nnkIdentDefs, ident("signalValue"), copyNimTree(typeIdent), newEmptyNode()
        )
      ]
    result.add(
      buildBindTemplates(
        typeIdent, "onSignal", "bindSignalHandler", @[slot], awaitCall = true
      )
    )
    result.add(
      buildBindTemplates(
        typeIdent,
        "replaceSignalHandler",
        "rebindSignalHandler",
        @[slot],
        awaitCall = true,
      )
    )

    # ── onSignalIt body sugar (issue #46, per-type since #51) ───────
    result.add(
      buildItSugarTemplates(
        typeIdent,
        "onSignal",
        "onSignalIt",
        "brokerSignal",
        futureVoidTy(),
        procTyPragma(handlerProcTy),
        isVoid,
      )
    )

  when defined(brokerDebug):
    writeBrokerDebug("SignalBrokerMt", typeDisplayName, result)
    when defined(brokerDebugStdout):
      echo result.repr

  return result

{.pop.}
