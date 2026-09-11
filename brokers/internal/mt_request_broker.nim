## Multi-Thread RequestBroker
## --------------------------
## Generates a multi-thread capable RequestBroker where the provider runs
## on the thread that called `setProvider` (which must keep its chronos
## event loop running), and requests from other threads are routed via
## a lock-free Vyukov MPSC ring + per-bucket payload slab + response slot
## pool.
##
## Same-thread requests bypass the ring and call the provider directly.
##
## See `doc/REFACTOR_MT_QUEUE.md` for the full design; this file is the
## RequestBroker integration of Phase 4 of that plan.
##
## §2.6 safety contract honored by construction (Invariant I0):
##   - The bucket-owning thread (the provider thread, the one that
##     called `setProvider`) allocates its ring + request slab +
##     response slot pool via `createShared`, and frees them via
##     `clearProvider` on the same thread.
##   - Sender threads only ever touch atomics + memcpy + signal-fire on
##     the hot path — never the Nim allocator beyond `claim`/`release`
##     of pre-allocated slab cells and response slots.

{.push raises: [].}

import std/[macros, strutils, locks, os, atomics, options]
import chronos, chronicles
import results
import ./helper/broker_utils, ../broker_context

import ./mt_broker_common, ./mt_queue, ./mt_codec, ./mt_config
import ./broker_debug
export
  results, chronos, chronicles, broker_context, mt_broker_common, mt_config, options
# The generated provideIt/reprovideIt templates expand `providerBody` at the
# user's call site, so the checker macro must be visible there.
export providerBody

# Capacity defaults moved to `mt_config.nim` and re-exported via the
# `mt_config` module so existing references to `DefaultMtReq*` constants
# continue to resolve.

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

proc generateMtRequestBroker*(
    body: NimNode, cfgIn: MtReqCfg = defaultMtReqCfg()
): NimNode =
  when defined(brokerDebug):
    echo body.treeRepr
    echo "RequestBroker mode: mt"

  # Classify legacy (`proc signature*`) vs proc-sugar (lowercase verb procs).
  # Mirrors request_broker.nim; MT is always async.
  var hasSignatureProc = false
  var hasOtherProc = false
  for stmt in body:
    if stmt.kind == nnkProcDef:
      let nm = stmt[0]
      let nmId = (if nm.kind == nnkPostfix: nm[1] else: nm)
      if ($nmId).startsWith("signature"):
        hasSignatureProc = true
      else:
        hasOtherProc = true
  let isSugar = hasOtherProc and not hasSignatureProc

  var typeIdent: NimNode = nil
  var objectDef: NimNode = nil
  var payloadType: NimNode = nil
  var responseFieldTypes: seq[NimNode] = @[]
  var zeroArgSig: NimNode = nil
  var zeroArgProviderName: NimNode = nil
  var argSig: NimNode = nil
  var argParams: seq[NimNode] = @[]
  var argProviderName: NimNode = nil
  var brokerDocText = ""

  if not isSugar:
    let parsed = parseSingleTypeDef(
      body, "RequestBroker", allowRefToNonObject = true, collectFieldInfo = true
    )
    typeIdent = parsed.typeIdent
    objectDef = parsed.objectDef
    responseFieldTypes = parsed.fieldTypes
    payloadType = copyNimTree(typeIdent) # legacy: dispatch tag == payload
    brokerDocText = parsed.docText

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
          zeroArgProviderName = ident(sanitizeIdentName(typeIdent) & "ProviderNoArgs")
        elif paramCount >= 1:
          if argSig != nil:
            error("Only one argument-based signature is allowed", stmt)
          argSig = stmt
          argParams = @[]
          for idx in 1 ..< params.len:
            let paramDef = params[idx]
            if paramDef.kind != nnkIdentDefs:
              error(
                "Signature parameter must be a standard identifier declaration",
                paramDef,
              )
            let paramTypeNode = paramDef[paramDef.len - 2]
            if paramTypeNode.kind == nnkEmpty:
              error("Signature parameter must declare a type", paramDef)
            argParams.add(copyNimTree(paramDef))
          argProviderName = ident(sanitizeIdentName(typeIdent) & "ProviderWithArgs")
      of nnkTypeSection, nnkEmpty, nnkCommentStmt:
        discard
      else:
        error("Unsupported statement inside RequestBroker definition", stmt)

    if zeroArgSig.isNil() and argSig.isNil():
      zeroArgSig = newEmptyNode()
      zeroArgProviderName = ident(sanitizeIdentName(typeIdent) & "ProviderNoArgs")
  else:
    # ---- New proc-sugar form (option B / decoupled payload) ----
    let sg = parseRequestSugar(body, "RequestBroker", async = true)
    typeIdent = sg.typeIdent
    objectDef = sg.objectDef
    payloadType = sg.payloadType
    responseFieldTypes = sg.fieldTypes
    brokerDocText = sg.docText
    if not sg.zeroArgProc.isNil:
      zeroArgSig = sg.zeroArgProc
      zeroArgProviderName = ident(sanitizeIdentName(typeIdent) & "ProviderNoArgs")
    if not sg.argProc.isNil:
      argSig = sg.argProc
      argParams = sg.argParams
      argProviderName = ident(sanitizeIdentName(typeIdent) & "ProviderWithArgs")

  let exportedTypeIdent = postfix(copyNimTree(typeIdent), "*")
  let typeDisplayName = sanitizeIdentName(typeIdent)
  let typeNameLit = newLit(typeDisplayName)
  # Opaque handle for cancellation: (slotIdx shl 32) or slotGen. A value, not
  # a pointer — nothing to allocate, nothing to free, and a handle whose slot
  # has since been recycled simply fails the generation check.
  let requestIdName = ident(typeDisplayName & "RequestId")
  # Cancel implementation. Lives under a unique name so generated code can call
  # it without colliding with chronos's `cancel(FutureBase)` template — inside
  # `quote do` a bare `cancel` binds to that template at the macro's own
  # definition site.
  let cancelByIdIdent = ident("cancelById" & typeDisplayName)

  let returnType = quote:
    Future[Result[`payloadType`, string]]

  # ── Type-driven auto-defaults ───────────────────────────────────────
  # Void / zero-field response and zero-arg signatures collapse to the
  # scalar bucket: nothing larger than the Result envelope's tag bytes
  # ever traverses the wire. Leaving the conservative 64 KB response /
  # 1 KB payload default in place would otherwise pin a 16 MB response
  # pool per RequestBroker for what is effectively a notification.
  var cfg = cfgIn
  if cfg.maxResponseBytesOrigin == "default":
    if responseFieldTypes.len > 0:
      let cls = classifyFieldsMax(responseFieldTypes)
      cfg.maxResponseBytes = cls.bytes
      cfg.maxResponseBytesOrigin = "auto:" & cls.reason
      if cls.reason.startsWith("unclassifiable"):
        warning(
          "[brokers] RequestBroker(" & typeDisplayName &
            ") could not auto-size response (" & cls.reason & "); falling back to " &
            $cls.bytes & " B. Override with `maxResponseBytes = N`."
        )
    else:
      cfg.maxResponseBytes = ScalarBytes
      cfg.maxResponseBytesOrigin = "auto:void"
  if cfg.maxPayloadBytesOrigin == "default":
    if argParams.len > 0:
      var argTypes = newSeqOfCap[NimNode](argParams.len)
      for p in argParams:
        argTypes.add(p[p.len - 2])
      let cls = classifyFieldsMax(argTypes)
      cfg.maxPayloadBytes = cls.bytes
      cfg.maxPayloadBytesOrigin = "auto:" & cls.reason
      if cls.reason.startsWith("unclassifiable"):
        warning(
          "[brokers] RequestBroker(" & typeDisplayName &
            ") could not auto-size request payload (" & cls.reason &
            "); falling back to " & $cls.bytes &
            " B. Override with `maxPayloadBytes = N`."
        )
    else:
      cfg.maxPayloadBytes = ScalarBytes
      cfg.maxPayloadBytesOrigin = "auto:void"

  when not defined(brokerConfigSilent):
    hint(fmtReqCfgSummary(typeDisplayName, cfg))

  # ── Identifier setup ────────────────────────────────────────────────
  let requestMsgName = ident(typeDisplayName & "MtRequestMsg")
  let bucketName = ident(typeDisplayName & "MtBucket")

  let globalBucketsIdent = ident("g" & typeDisplayName & "MtBuckets")
  let globalBucketCountIdent = ident("g" & typeDisplayName & "MtBucketCount")
  let globalBucketCapIdent = ident("g" & typeDisplayName & "MtBucketCap")
  let globalLockIdent = ident("g" & typeDisplayName & "MtLock")
  let globalInitIdent = ident("g" & typeDisplayName & "MtInit")
  let timeoutVarIdent = ident("g" & typeDisplayName & "MtTimeout")

  let initProcIdent = ident("ensureInit" & typeDisplayName & "MtBroker")
  let growProcIdent = ident("grow" & typeDisplayName & "MtBuckets")
  let sendReplyIdent = ident("sendReply" & typeDisplayName)
  let handleMsgIdent = ident("handleMsg" & typeDisplayName)
  let pollFnMakerIdent = ident("makePollFn" & typeDisplayName)
  let shardHintIdent = ident("shardHint" & typeDisplayName)
  let marshalIdent = ident(typeDisplayName & "MtMarshal")
  let unmarshalIdent = ident(typeDisplayName & "MtUnmarshal")
  let marshalSizeIdent = ident(typeDisplayName & "MtMarshalSize")
  let marshalRespIdent = ident(typeDisplayName & "MtMarshalResp")
  let unmarshalRespIdent = ident(typeDisplayName & "MtUnmarshalResp")
  let marshalRespSizeIdent = ident(typeDisplayName & "MtMarshalRespSize")

  let queueDepthLit = newLit(cfg.queueDepth)
  let slabCapacityLit = newLit(cfg.slabCapacity)
  let payloadBytesLit = newLit(cfg.maxPayloadBytes)
  let maxDynPayloadLit = newLit(cfg.maxDynamicPayloadBytes)
  let responseSlotsLit = newLit(cfg.responseSlots)
  let requestTimeoutMsLit = newLit(cfg.requestTimeoutMs)
  let responseBytesLit = newLit(cfg.maxResponseBytes)
  let freeListShardsLit = newLit(uint32(cfg.freeListShards))

  result = newStmtList()

  # ── Type section (typeIdent + provider proc types) ───────────────────
  var typeSection = newTree(nnkTypeSection)
  typeSection.add(
    typeDefWithDoc(
      newTree(nnkTypeDef, exportedTypeIdent, newEmptyNode(), objectDef), brokerDocText
    )
  )

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

  # Request message struct. Carries args inline plus a response-slot
  # index (the per-bucket pool index where the provider writes the
  # result) and the requester's signal pointer (so the provider can
  # wake the requester's dispatcher after writing).
  var msgRecList = newTree(nnkRecList)
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
  msgRecList.add(
    newTree(nnkIdentDefs, ident("responseSlotIdx"), ident("uint32"), newEmptyNode())
  )
  # Generation of the response slot at claim time. The provider CASes against
  # it, so a reply that arrives after the slot was recycled is dropped instead
  # of overwriting the new owner's response.
  msgRecList.add(
    newTree(nnkIdentDefs, ident("responseSlotGen"), ident("uint32"), newEmptyNode())
  )
  msgRecList.add(
    newTree(
      nnkIdentDefs,
      ident("requesterSignal"),
      newTree(nnkPtrTy, ident("BrokerSignalShared")),
      newEmptyNode(),
    )
  )
  typeSection.add(
    newTree(
      nnkTypeDef,
      requestMsgName,
      newEmptyNode(),
      newTree(nnkObjectTy, newEmptyNode(), newEmptyNode(), msgRecList),
    )
  )

  # Bucket struct.
  let responseSlotPoolType = quote:
    ptr ResponseSlotPool
  let requestRingType = quote:
    ptr VyukovMpscRing[uint32]
  let requestSlabType = quote:
    ptr PayloadSlab

  var bucketRecList = newTree(nnkRecList)
  bucketRecList.add(
    newTree(nnkIdentDefs, ident("brokerCtx"), ident("BrokerContext"), newEmptyNode())
  )
  bucketRecList.add(
    newTree(nnkIdentDefs, ident("ring"), requestRingType, newEmptyNode())
  )
  bucketRecList.add(
    newTree(nnkIdentDefs, ident("slab"), requestSlabType, newEmptyNode())
  )
  bucketRecList.add(
    newTree(
      nnkIdentDefs, ident("responseSlotPool"), responseSlotPoolType, newEmptyNode()
    )
  )
  bucketRecList.add(
    newTree(
      nnkIdentDefs,
      ident("providerSignal"),
      newTree(nnkPtrTy, ident("BrokerSignalShared")),
      newEmptyNode(),
    )
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

  typeSection.add(
    newTree(
      nnkTypeDef,
      postfix(copyNimTree(requestIdName), "*"),
      newEmptyNode(),
      newTree(nnkDistinctTy, ident("uint64")),
    )
  )

  result.add(typeSection)
  # `==` is built by hand: inside `quote do` the backticks around an operator
  # name are interpolation syntax, not an identifier.
  result.add(
    newProc(
      name = postfix(nnkAccQuoted.newTree(ident("==")), "*"),
      params = @[
        ident("bool"),
        newIdentDefs(ident("a"), copyNimTree(requestIdName)),
        newIdentDefs(ident("b"), copyNimTree(requestIdName)),
      ],
      body = newEmptyNode(),
      pragmas = nnkPragma.newTree(ident("borrow")),
    )
  )
  result.add(
    quote do:
      proc isCancellable*(id: `requestIdName`): bool =
        ## False for a request that was never armed (same-thread call, or a
        ## prologue that failed) — such an id can never be cancelled.
        uint64(id) != 0'u64

  )

  # ── Codec procs for ReqMsg ───────────────────────────────────────────
  for procNode in genMtCodecProcs(marshalIdent, unmarshalIdent, requestMsgName):
    result.add(procNode)

  # ── Codec procs for Result[typeIdent, string] ───────────────────────
  # Custom — `Result` is a case object on `oResultPrivate`; the generic
  # `fieldPairs`-based marshaler would touch the wrong-tag fields. We
  # encode an explicit `isOk` byte followed by either the value (T) or
  # the error (string), recursively via mtMarshalValue/Unmarshal.
  result.add(
    quote do:
      proc `marshalRespIdent`(
          buf: ptr UncheckedArray[byte], cap: int, res: Result[`payloadType`, string]
      ): int {.gcsafe, raises: [].} =
        var pos = 0
        if pos + 1 > cap:
          return -1
        let isOk = byte(if res.isOk: 1 else: 0)
        buf[pos] = isOk
        pos += 1
        if res.isOk:
          when not (`payloadType` is void):
            let val = res.value
            if not mtMarshalValue(buf, cap, val, pos):
              return -1
        else:
          let errMsg = res.error
          if not mtMarshalValue(buf, cap, errMsg, pos):
            return -1
        return pos

      proc `unmarshalRespIdent`(
          buf: ptr UncheckedArray[byte],
          len: int,
          dst: var Result[`payloadType`, string],
      ): bool {.gcsafe, raises: [].} =
        var pos = 0
        if pos + 1 > len:
          return false
        let isOk = buf[pos]
        pos += 1
        if isOk == 1'u8:
          when (`payloadType` is void):
            dst.ok()
          else:
            var val: `payloadType`
            if not mtUnmarshalValue(buf, len, val, pos):
              return false
            dst = ok(Result[`payloadType`, string], val)
        else:
          var errMsg: string
          if not mtUnmarshalValue(buf, len, errMsg, pos):
            return false
          dst = err(Result[`payloadType`, string], errMsg)
        return true

      proc `marshalRespSizeIdent`(
          res: Result[`payloadType`, string]
      ): int {.gcsafe, raises: [].} =
        ## Exact marshaled byte length of a response — mirrors `marshalRespIdent`
        ## (1 isOk byte + value-or-error). Used to size a heap-spill buffer.
        result = 1
        if res.isOk:
          when not (`payloadType` is void):
            result += mtMarshalSizeValue(res.value)
        else:
          result += mtMarshalSizeValue(res.error)

  )

  # ── Global state ────────────────────────────────────────────────────
  result.add(
    quote do:
      var `globalBucketsIdent`: ptr UncheckedArray[`bucketName`]
      var `globalBucketCountIdent`: int
      var `globalBucketCapIdent`: int
      var `globalLockIdent`: Lock
      var `globalInitIdent`: Atomic[int]
  )

  # ── Timeout knob (per broker type) ──────────────────────────────────
  result.add(
    quote do:
      var `timeoutVarIdent`*: Duration = chronos.milliseconds(`requestTimeoutMsLit`)
        ## Timeout for cross-thread requests, seeded from the declaration's
        ## `requestTimeoutMs` kwarg (default 20 s) and mutable at runtime via
        ## `setRequestTimeout`.

      proc setRequestTimeout*(_: typedesc[`typeIdent`], timeout: Duration) =
        `timeoutVarIdent` = timeout

      proc requestTimeout*(_: typedesc[`typeIdent`]): Duration =
        `timeoutVarIdent`

  )

  # ── Init + grow ──────────────────────────────────────────────────────
  result.add(
    quote do:
      proc `initProcIdent`() =
        if `globalInitIdent`.load(moRelaxed) == 2:
          return
        var expected = 0
        if `globalInitIdent`.compareExchange(expected, 1, moAcquire, moRelaxed):
          initLock(`globalLockIdent`)
          `globalBucketCapIdent` = 4
          `globalBucketsIdent` = cast[ptr UncheckedArray[`bucketName`]](createShared(
            `bucketName`, `globalBucketCapIdent`
          ))
          `globalBucketCountIdent` = 0
          `globalInitIdent`.store(2, moRelease)
        else:
          while `globalInitIdent`.load(moAcquire) != 2:
            discard

      proc `growProcIdent`() =
        let newCap = `globalBucketCapIdent` * 2
        let newBuf =
          cast[ptr UncheckedArray[`bucketName`]](createShared(`bucketName`, newCap))
        for i in 0 ..< `globalBucketCountIdent`:
          newBuf[i] = `globalBucketsIdent`[i]
        `globalBucketsIdent` = newBuf
        `globalBucketCapIdent` = newCap

      proc `shardHintIdent`(): uint32 {.inline.} =
        cast[uint32](cast[uint](currentMtThreadId()) shr 4)

  )

  # ── Threadvar provider storage ──────────────────────────────────────
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

  # ── provider-side in-flight registry ────────────────────────────────
  # Requests currently executing on this provider thread, keyed by the
  # response slot they will answer. `asyncSpawn` throws the future away, so
  # without this there is nothing left to cancel once a provider is running.
  # Owned by the provider thread; only ever touched from its dispatch loop.
  let tvInFlightIdent = ident("g" & typeDisplayName & "TvInFlight")
  let registerInFlightIdent = ident("registerInFlight" & typeDisplayName)
  let unregisterInFlightIdent = ident("unregisterInFlight" & typeDisplayName)
  let scanCancelledIdent = ident("scanCancelled" & typeDisplayName)
  result.add(
    quote do:
      var `tvInFlightIdent` {.threadvar.}:
        seq[tuple[sIdx: uint32, sGen: uint32, fut: FutureBase]]

      proc `registerInFlightIdent`(
          slotIdx: uint32, slotGen: uint32, fut: FutureBase
      ) {.gcsafe, raises: [].} =
        {.cast(gcsafe).}:
          `tvInFlightIdent`.add((sIdx: slotIdx, sGen: slotGen, fut: fut))

      proc `unregisterInFlightIdent`(slotIdx: uint32) {.gcsafe, raises: [].} =
        {.cast(gcsafe).}:
          for i in 0 ..< `tvInFlightIdent`.len:
            if `tvInFlightIdent`[i].sIdx == slotIdx:
              `tvInFlightIdent`.del(i)
              break

      proc `scanCancelledIdent`(pool: ptr ResponseSlotPool) {.gcsafe, raises: [].} =
        ## Runs only when the pool's cancel epoch moved, so the hot path pays
        ## one relaxed load rather than a scan.
        {.cast(gcsafe).}:
          for entry in `tvInFlightIdent`:
            if pool[].isAbandoned(entry.sIdx, entry.sGen) and not entry.fut.finished():
              entry.fut.cancelSoon()

  )

  # ── sendReply helper (marshals Result into response slot bytes) ──────
  # Protocol:
  #   1. CAS (gen, Empty)→(gen, Writing) via pool.beginWrite:
  #        Acquired  — carry on;
  #        Abandoned — requester gave up, provider owns the release;
  #        Stale     — slot already recycled for a newer request; drop the
  #                    reply and touch nothing (releasing here would hand a
  #                    live slot to a second owner).
  #   2. Marshal `resp` into slotPayloadPtr(idx).
  #   3. commitWrite (stores size + flips state to Ready, release-ordered).
  #   4. Fire requester's signal.
  result.add(
    quote do:
      proc `sendReplyIdent`(
          pool: ptr ResponseSlotPool,
          slotIdx: uint32,
          slotGen: uint32,
          requesterSignal: ptr BrokerSignalShared,
          resp: Result[`payloadType`, string],
      ) {.gcsafe, raises: [].} =
        if pool.isNil or slotIdx == EmptyIdx:
          return
        case pool[].beginWrite(slotIdx, slotGen)
        of BeginWriteResult.Abandoned:
          # Requester already abandoned — provider owns the release.
          pool[].release(slotIdx, `shardHintIdent`())
          return
        of BeginWriteResult.Stale:
          return
        of BeginWriteResult.Acquired:
          discard
        let payloadPtr = pool[].slotPayloadPtr(slotIdx)
        # False from any commit below means the requester gave up mid-write, so
        # the response is unwanted and the slot is ours to hand back.
        var published = false
        let written =
          try:
            `marshalRespIdent`(payloadPtr, int(pool[].slotPayloadCap), resp)
          except Exception:
            -1
        if written >= 0:
          published = pool[].commitWrite(slotIdx, slotGen, uint32(written))
        else:
          # Response exceeded the inline slot — auto-spill onto the heap so the
          # full response is delivered instead of replaced by an err. Falls back
          # to an err only if the spill itself cannot be sized/allocated.
          let needed =
            try:
              `marshalRespSizeIdent`(resp)
            except Exception:
              -1
          var spilled = false
          if needed >= 0 and needed <= `maxDynPayloadLit`:
            let spillBuf = allocShared0(needed)
            if not spillBuf.isNil:
              let w2 =
                try:
                  `marshalRespIdent`(
                    cast[ptr UncheckedArray[byte]](spillBuf), needed, resp
                  )
                except Exception:
                  -1
              if w2 < 0:
                deallocShared(spillBuf)
              else:
                published =
                  pool[].commitWriteOverflow(slotIdx, slotGen, spillBuf, uint32(w2))
                spilled = true
          if not spilled:
            # Could not spill (over ceiling / OOM / marshal error) — commit a
            # compact err so the requester gets a clean failure, not garbage.
            let fallback = err(
              Result[`payloadType`, string],
              "RequestBroker(" & `typeNameLit` & "): response too large to deliver",
            )
            let writtenFb =
              try:
                `marshalRespIdent`(payloadPtr, int(pool[].slotPayloadCap), fallback)
              except Exception:
                -1
            if writtenFb < 0:
              published = pool[].commitWrite(slotIdx, slotGen, 0'u32)
            else:
              published = pool[].commitWrite(slotIdx, slotGen, uint32(writtenFb))
        if not published:
          # Requester abandoned while we were writing — nobody is waiting for
          # this response, and the release is ours.
          pool[].release(slotIdx, `shardHintIdent`())
          return
        if not requesterSignal.isNil:
          fireBrokerSignal(requesterSignal)

  )

  # ── handleMsg async (provider-side dispatch of a single ReqMsg) ──────
  let msgIdent = ident("msg")
  let loopCtxIdent = ident("loopCtx")
  let poolIdent = ident("pool")

  var handleBody = newStmtList()

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
              `poolIdent`,
              `msgIdent`.responseSlotIdx,
              `msgIdent`.responseSlotGen,
              `msgIdent`.requesterSignal,
              err(
                Result[`payloadType`, string],
                "RequestBroker(" & `typeNameLit` & "): no zero-arg provider registered",
              ),
            )
          else:
            let providerFut = `handlerIdent0`()
            `registerInFlightIdent`(
              `msgIdent`.responseSlotIdx, `msgIdent`.responseSlotGen, providerFut
            )
            let catchedRes = catch:
              await providerFut
            `unregisterInFlightIdent`(`msgIdent`.responseSlotIdx)
            if catchedRes.isErr():
              `sendReplyIdent`(
                `poolIdent`,
                `msgIdent`.responseSlotIdx,
                `msgIdent`.responseSlotGen,
                `msgIdent`.requesterSignal,
                err(
                  Result[`payloadType`, string],
                  "RequestBroker(" & `typeNameLit` & "): provider threw exception: " &
                    catchedRes.error.msg,
                ),
              )
            else:
              let providerRes = catchedRes.get()
              when not (`payloadType` is void):
                if providerRes.isOk():
                  let resultValue = providerRes.get()
                  when compiles(resultValue.isNil()) and
                      not (typeof(resultValue) is string):
                    if resultValue.isNil():
                      `sendReplyIdent`(
                        `poolIdent`,
                        `msgIdent`.responseSlotIdx,
                        `msgIdent`.responseSlotGen,
                        `msgIdent`.requesterSignal,
                        err(
                          Result[`payloadType`, string],
                          "RequestBroker(" & `typeNameLit` &
                            "): provider returned nil result",
                        ),
                      )
                      return
              `sendReplyIdent`(
                `poolIdent`, `msgIdent`.responseSlotIdx, `msgIdent`.responseSlotGen,
                `msgIdent`.requesterSignal, providerRes,
              )
    )

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
              `poolIdent`,
              `msgIdent`.responseSlotIdx,
              `msgIdent`.responseSlotGen,
              `msgIdent`.requesterSignal,
              err(
                Result[`payloadType`, string],
                "RequestBroker(" & `typeNameLit` &
                  "): no provider registered for input signature",
              ),
            )
          else:
            let providerFut = `providerCall`
            `registerInFlightIdent`(
              `msgIdent`.responseSlotIdx, `msgIdent`.responseSlotGen, providerFut
            )
            let catchedRes = catch:
              await providerFut
            `unregisterInFlightIdent`(`msgIdent`.responseSlotIdx)
            if catchedRes.isErr():
              `sendReplyIdent`(
                `poolIdent`,
                `msgIdent`.responseSlotIdx,
                `msgIdent`.responseSlotGen,
                `msgIdent`.requesterSignal,
                err(
                  Result[`payloadType`, string],
                  "RequestBroker(" & `typeNameLit` & "): provider threw exception: " &
                    catchedRes.error.msg,
                ),
              )
            else:
              let providerRes = catchedRes.get()
              when not (`payloadType` is void):
                if providerRes.isOk():
                  let resultValue = providerRes.get()
                  when compiles(resultValue.isNil()) and
                      not (typeof(resultValue) is string):
                    if resultValue.isNil():
                      `sendReplyIdent`(
                        `poolIdent`,
                        `msgIdent`.responseSlotIdx,
                        `msgIdent`.responseSlotGen,
                        `msgIdent`.requesterSignal,
                        err(
                          Result[`payloadType`, string],
                          "RequestBroker(" & `typeNameLit` &
                            "): provider returned nil result",
                        ),
                      )
                      return
              `sendReplyIdent`(
                `poolIdent`, `msgIdent`.responseSlotIdx, `msgIdent`.responseSlotGen,
                `msgIdent`.requesterSignal, providerRes,
              )
    )

  result.add(
    quote do:
      proc `handleMsgIdent`(
          `msgIdent`: `requestMsgName`,
          `loopCtxIdent`: BrokerContext,
          `poolIdent`: ptr ResponseSlotPool,
      ) {.async: (raises: []).} =
        `handleBody`

  )

  # ── Poll fn maker ────────────────────────────────────────────────────
  # Dequeues cell idx from ring, unmarshals ReqMsg, dispatches.  When the
  # ring is closed and empty, registers its (ring, slab, pool) triple for
  # synchronous deferred free at thread exit (see drainPendingRingFrees).
  result.add(
    quote do:
      proc `pollFnMakerIdent`(
          ring: ptr VyukovMpscRing[uint32],
          slab: ptr PayloadSlab,
          pool: ptr ResponseSlotPool,
          loopCtx: BrokerContext,
      ): ThreadDispatchPollFn =
        let capturedRing = ring
        let capturedSlab = slab
        let capturedPool = pool
        let capturedCtx = loopCtx
        var lastCancelEpoch = capturedPool[].cancelEpochValue()
        return proc(): int {.gcsafe, raises: [].} =
          {.cast(gcsafe).}:
            let epoch = capturedPool[].cancelEpochValue()
            if epoch != lastCancelEpoch:
              lastCancelEpoch = epoch
              `scanCancelledIdent`(capturedPool)
            var cellIdx: uint32
            if not capturedRing.tryDequeue(cellIdx):
              if capturedRing.isClosed():
                # Hand off to the thread-local pending-free registry; the
                # processing-thread proc drains it synchronously after
                # drainAsyncOps. Doing the free asynchronously here ran the
                # refc allocator during shutdown teardown and SEGV'd on
                # Linux + macOS ASAN (PR #13, deferredFreeReqRing path).
                enqueuePendingRingFree(capturedRing, capturedSlab, capturedPool)
                return 2
              return 0
            # Got a cell — unmarshal ReqMsg, dispatch. dataPtr/dataLen resolve
            # the heap-spill buffer when the request spilled, else inline.
            var msg: `requestMsgName`
            let payloadPtr = capturedSlab[].dataPtr(cellIdx)
            let payloadLen = capturedSlab[].dataLen(cellIdx)
            let ok =
              try:
                `unmarshalIdent`(payloadPtr, payloadLen, msg)
              except Exception:
                false
            if ok:
              if capturedPool[].isAbandoned(msg.responseSlotIdx, msg.responseSlotGen):
                # Cancelled (or timed out) before we got to it: the requester's
                # CAS won, so the slot is ours to release and the provider is
                # never invoked. A ring cannot drop an element, so a dead
                # request is tombstoned in the slot and skipped here.
                capturedPool[].release(msg.responseSlotIdx, `shardHintIdent`())
              else:
                asyncSpawn `handleMsgIdent`(msg, capturedCtx, capturedPool)
            else:
              error "Failed to unmarshal request payload", requestType = `typeNameLit`
            # Release the cell back to the slab — the unmarshaled msg
            # holds its own copy on this thread's GC heap.
            capturedSlab[].release(cellIdx, `shardHintIdent`())
            return 1

  )

  # ── setProvider impl helper (reused by 4 public overloads) ───────────
  # Allocates ring + slab + pool on the calling thread, registers the
  # bucket, and starts the poller.  Returns Result[void, string].
  let setupBucketIdent = ident("setupBucket" & typeDisplayName)
  result.add(
    quote do:
      proc `setupBucketIdent`(brokerCtx: BrokerContext): Result[void, string] =
        let myThreadId = currentMtThreadId()
        let myThreadGen = currentMtThreadGen()
        var ring: ptr VyukovMpscRing[uint32]
        var slab: ptr PayloadSlab
        var pool: ptr ResponseSlotPool
        withLock(`globalLockIdent`):
          for i in 0 ..< `globalBucketCountIdent`:
            if `globalBucketsIdent`[i].brokerCtx == brokerCtx:
              if `globalBucketsIdent`[i].threadId == myThreadId and
                  `globalBucketsIdent`[i].threadGen == myThreadGen:
                return ok() # already set on this thread
              return err(
                "RequestBroker(" & `typeNameLit` &
                  "): provider already set from another thread"
              )
          if `globalBucketCountIdent` >= `globalBucketCapIdent`:
            `growProcIdent`()
          ring = newVyukovMpscRing[uint32](`queueDepthLit`)
          slab = cast[ptr PayloadSlab](createShared(PayloadSlab, 1))
          initPayloadSlab(
            slab[],
            capacity = uint32(`slabCapacityLit`),
            payloadBytes = uint32(`payloadBytesLit`),
            nShards = `freeListShardsLit`,
          )
          pool = cast[ptr ResponseSlotPool](createShared(ResponseSlotPool, 1))
          initResponseSlotPool(
            pool[],
            capacity = uint32(`responseSlotsLit`),
            maxPayloadBytes = uint32(`responseBytesLit`),
            nShards = `freeListShardsLit`,
          )
          let providerSig = getOrInitBrokerSignal()
          let idx = `globalBucketCountIdent`
          `globalBucketsIdent`[idx] = `bucketName`(
            brokerCtx: brokerCtx,
            ring: ring,
            slab: slab,
            responseSlotPool: pool,
            providerSignal: providerSig,
            threadId: myThreadId,
            threadGen: myThreadGen,
          )
          `globalBucketCountIdent` += 1
        registerBrokerPoller(`pollFnMakerIdent`(ring, slab, pool, brokerCtx))
        ensureBrokerDispatchStarted()
        ok()

  )

  # ── setProvider (zero-arg) ──────────────────────────────────────────
  if not zeroArgSig.isNil():
    result.add(
      quote do:
        proc setProvider*(
            _: typedesc[`typeIdent`],
            brokerCtx: BrokerContext,
            handler: `zeroArgProviderName`,
        ): Result[void, string] =
          `initProcIdent`()
          let myThreadGen = currentMtThreadGen()
          for i in 0 ..< `tvNoArgCtxIdent`.len:
            if `tvNoArgCtxIdent`[i] == brokerCtx:
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
                    "): provider already set for broker context"
                )
          `tvNoArgCtxIdent`.add(brokerCtx)
          `tvNoArgHandlerIdent`.add(handler)
          let r = `setupBucketIdent`(brokerCtx)
          if r.isErr():
            `tvNoArgCtxIdent`.setLen(`tvNoArgCtxIdent`.len - 1)
            `tvNoArgHandlerIdent`.setLen(`tvNoArgHandlerIdent`.len - 1)
            return r
          ok()

        proc setProvider*(
            _: typedesc[`typeIdent`], handler: `zeroArgProviderName`
        ): Result[void, string] =
          setProvider(`typeIdent`, DefaultBrokerContext, handler)

    )

  # ── setProvider (with-args) ─────────────────────────────────────────
  if not argSig.isNil():
    result.add(
      quote do:
        proc setProvider*(
            _: typedesc[`typeIdent`],
            brokerCtx: BrokerContext,
            handler: `argProviderName`,
        ): Result[void, string] =
          `initProcIdent`()
          let myThreadGen = currentMtThreadGen()
          for i in 0 ..< `tvWithArgCtxIdent`.len:
            if `tvWithArgCtxIdent`[i] == brokerCtx:
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
                    "): provider already set for broker context"
                )
          `tvWithArgCtxIdent`.add(brokerCtx)
          `tvWithArgHandlerIdent`.add(handler)
          let r = `setupBucketIdent`(brokerCtx)
          if r.isErr():
            `tvWithArgCtxIdent`.setLen(`tvWithArgCtxIdent`.len - 1)
            `tvWithArgHandlerIdent`.setLen(`tvWithArgHandlerIdent`.len - 1)
            return r
          ok()

        proc setProvider*(
            _: typedesc[`typeIdent`], handler: `argProviderName`
        ): Result[void, string] =
          setProvider(`typeIdent`, DefaultBrokerContext, handler)

    )

  # ── give-up helper: shared by every requester-side bail-out path ─────
  # Publishes "this requester stopped waiting" on the response slot. The slot
  # state machine settles ownership on the spot — the provider releases unless
  # it has already published, in which case we release here — so no bail-out
  # path ever has to wait for the provider. Firing our own dispatch signal then
  # forces a drain pass so the response poller retires immediately instead of
  # lingering until some unrelated wake.
  let giveUpIdent = ident("giveUp" & typeDisplayName)
  result.add(
    quote do:
      proc `giveUpIdent`(
          waitState: ReqWaitState,
          pool: ptr ResponseSlotPool,
          slotIdx: uint32,
          slotGen: uint32,
          mySignal: ptr BrokerSignalShared,
      ) {.gcsafe, raises: [].} =
        waitState.gaveUp = true
        if pool[].giveUpSlot(slotIdx, slotGen) == SlotGiveUp.CallerReleases:
          pool[].release(slotIdx, `shardHintIdent`())
        fireBrokerSignal(mySignal)

  )

  # ── request prologue: claim + marshal + enqueue (synchronous) ────────
  # Everything up to and including the provider wake-up, kept out of the async
  # tail. That is what lets `requestCancellable` hand its id back before the
  # caller can possibly await: by the time a cancel is expressible, the request
  # is already armed, so there is no "cancel arrives before arming" window to
  # close.
  let prologueName = ident(typeDisplayName & "SendPrologue")
  let sendPrologueIdent = ident("sendPrologue" & typeDisplayName)
  result.add(
    quote do:
      type `prologueName` = object
        slotIdx: uint32
        slotGen: uint32
        error: string ## empty on success

      proc `sendPrologueIdent`(
          ring: ptr VyukovMpscRing[uint32],
          slab: ptr PayloadSlab,
          pool: ptr ResponseSlotPool,
          providerSignal: ptr BrokerSignalShared,
          mySignal: ptr BrokerSignalShared,
          msg: sink `requestMsgName`,
      ): `prologueName` {.gcsafe, raises: [].} =
        # Reserve the response slot.
        let slotIdx = pool[].claim(`shardHintIdent`())
        if slotIdx == EmptyIdx:
          return `prologueName`(
            slotIdx: EmptyIdx,
            error: "RequestBroker(" & `typeNameLit` & "): response slot pool exhausted",
          )
        # Read the generation while the slot is exclusively ours. Every later
        # action on it — provider reply, give-up, cancel, response poll — is
        # checked against this value, so a recycled slot can never be mistaken
        # for this request's.
        let slotGen = pool[].slotGen(slotIdx)
        # Record who to wake if a third thread cancels this request. `nil` for
        # blocking requesters: they poll the slot themselves.
        pool[].setWaker(slotIdx, mySignal)
        # Reserve a slab cell, marshal ReqMsg into it.
        let cellIdx = slab[].claim(`shardHintIdent`())
        if cellIdx == EmptyIdx:
          pool[].release(slotIdx, `shardHintIdent`())
          return `prologueName`(
            slotIdx: EmptyIdx,
            error: "RequestBroker(" & `typeNameLit` & "): request slab exhausted",
          )
        let cellPtr = slab[].cellPtr(cellIdx)
        let payloadPtr = slab[].cellPayloadPtr(cellIdx)
        var msgCopy = msg
        msgCopy.responseSlotIdx = slotIdx
        msgCopy.responseSlotGen = slotGen
        msgCopy.requesterSignal = mySignal
        let written =
          try:
            `marshalIdent`(payloadPtr, int(slab[].cellPayloadCap), msgCopy)
          except Exception:
            -1
        if written >= 0:
          cellPtr.payloadSize = uint32(written)
        else:
          # Auto-spill the request onto the heap instead of failing.
          let needed =
            try:
              `marshalSizeIdent`(msgCopy)
            except Exception:
              -1
          if needed < 0 or needed > `maxDynPayloadLit`:
            slab[].release(cellIdx, `shardHintIdent`())
            pool[].release(slotIdx, `shardHintIdent`())
            return `prologueName`(
              slotIdx: EmptyIdx,
              error:
                "RequestBroker(" & `typeNameLit` &
                "): request payload exceeds maxDynamicPayloadBytes",
            )
          let spillBuf = allocShared0(needed)
          if spillBuf.isNil:
            slab[].release(cellIdx, `shardHintIdent`())
            pool[].release(slotIdx, `shardHintIdent`())
            return `prologueName`(
              slotIdx: EmptyIdx,
              error: "RequestBroker(" & `typeNameLit` & "): request spill alloc failed",
            )
          let w2 =
            try:
              `marshalIdent`(cast[ptr UncheckedArray[byte]](spillBuf), needed, msgCopy)
            except Exception:
              -1
          if w2 < 0:
            deallocShared(spillBuf)
            slab[].release(cellIdx, `shardHintIdent`())
            pool[].release(slotIdx, `shardHintIdent`())
            return `prologueName`(
              slotIdx: EmptyIdx,
              error: "RequestBroker(" & `typeNameLit` & "): request marshal failed",
            )
          slab[].setOverflow(cellIdx, spillBuf, uint32(w2))
        cellPtr.refcount.store(1, moRelease)
        if not ring.tryEnqueue(cellIdx):
          slab[].release(cellIdx, `shardHintIdent`())
          pool[].release(slotIdx, `shardHintIdent`())
          return `prologueName`(
            slotIdx: EmptyIdx,
            error: "RequestBroker(" & `typeNameLit` & "): provider queue full",
          )
        fireBrokerSignal(providerSignal)
        `prologueName`(slotIdx: slotIdx, slotGen: slotGen, error: "")

  )

  # ── request tail: wait for the response slot ─────────────────────────
  # Returns the response Result, or an err on timeout / cancellation.
  let awaitReplyIdent = ident("awaitReply" & typeDisplayName)
  result.add(
    quote do:
      proc `awaitReplyIdent`(
          pool: ptr ResponseSlotPool,
          slotIdx: uint32,
          slotGen: uint32,
          mySignal: ptr BrokerSignalShared,
      ): Future[Result[`payloadType`, string]] {.async: (raises: []).} =
        let responseFut =
          newFuture[Result[`payloadType`, string]]("request." & `typeNameLit`)
        let capturedPool = pool
        let capturedSlotIdx = slotIdx
        let capturedSlotGen = slotGen
        let capturedResponseFut = responseFut
        let waitState = ReqWaitState()
        let capturedWait = waitState
        registerBrokerPoller(
          proc(): int {.gcsafe, raises: [].} =
            {.cast(gcsafe).}:
              if capturedWait.gaveUp:
                # Ownership was settled synchronously in giveUp, so the slot may
                # already be recycled — or the pool itself freed by the provider
                # thread's teardown. Retire without touching either.
                return 2
              if capturedPool[].isProviderGone(capturedSlotIdx, capturedSlotGen):
                # The provider was cleared out from under this request. No one
                # will answer it and no one else will hand the slot back.
                capturedWait.gaveUp = true
                if not capturedResponseFut.finished:
                  capturedResponseFut.complete(
                    err(
                      Result[`payloadType`, string],
                      "RequestBroker(" & `typeNameLit` &
                        "): provider was cleared while the request was outstanding",
                    )
                  )
                capturedPool[].release(capturedSlotIdx, `shardHintIdent`())
                return 2
              if capturedPool[].isAbandoned(capturedSlotIdx, capturedSlotGen):
                # Someone else cancelled this request. Their CAS won, so the
                # provider owes the release; we only resolve the caller.
                capturedWait.gaveUp = true
                if not capturedResponseFut.finished:
                  capturedResponseFut.complete(
                    err(
                      Result[`payloadType`, string],
                      "RequestBroker(" & `typeNameLit` & "): request cancelled",
                    )
                  )
                return 2
              if not capturedPool[].readyState(capturedSlotIdx, capturedSlotGen):
                return 0
              # Unmarshal Result from slot bytes on THIS (requester) thread,
              # so any string/seq inside lives on this thread's GC heap.
              # This is the §2.2 fix: no cross-thread `=copy` of the typed
              # Result value.
              var decoded: Result[`payloadType`, string]
              let payloadPtr = capturedPool[].respDataPtr(capturedSlotIdx)
              let payloadSize = capturedPool[].respDataLen(capturedSlotIdx)
              let ok =
                try:
                  `unmarshalRespIdent`(payloadPtr, payloadSize, decoded)
                except Exception:
                  false
              if not ok:
                decoded = err(
                  Result[`payloadType`, string],
                  "RequestBroker(" & `typeNameLit` & "): response unmarshal failed",
                )
              if not capturedResponseFut.finished:
                capturedResponseFut.complete(decoded)
              capturedPool[].release(capturedSlotIdx, `shardHintIdent`())
              return 2
        )
        let completedRes = catch:
          await withTimeout(responseFut, `timeoutVarIdent`)
        if completedRes.isErr():
          responseFut.cancelSoon()
          `giveUpIdent`(waitState, pool, slotIdx, slotGen, mySignal)
          return err(
            "RequestBroker(" & `typeNameLit` & "): recv failed: " &
              completedRes.error.msg
          )
        if not completedRes.get():
          responseFut.cancelSoon()
          `giveUpIdent`(waitState, pool, slotIdx, slotGen, mySignal)
          return err(
            "RequestBroker(" & `typeNameLit` & "): cross-thread request timed out after " &
              $`timeoutVarIdent`
          )
        let recvRes = catch:
          responseFut.read()
        if recvRes.isErr():
          return err(
            "RequestBroker(" & `typeNameLit` & "): recv failed: " & recvRes.error.msg
          )
        recvRes.get()

  )

  # ── cancel implementation (used by the public wrappers below and by
  # the owned-future cancel callback) ─────────────────────────────────
  result.add(
    quote do:
      proc `cancelByIdIdent`(
          brokerCtx: BrokerContext, id: `requestIdName`
      ): bool {.gcsafe, raises: [].} =
        `initProcIdent`()
        if uint64(id) == 0'u64:
          return false
        let slotIdx = uint32(uint64(id) shr 32)
        let slotGen = uint32(uint64(id) and 0xFFFFFFFF'u64)
        var won = false
        var providerSignal: ptr BrokerSignalShared = nil
        var requesterSignal: ptr BrokerSignalShared = nil
        withLock(`globalLockIdent`):
          for i in 0 ..< `globalBucketCountIdent`:
            if `globalBucketsIdent`[i].brokerCtx == brokerCtx:
              let pool = `globalBucketsIdent`[i].responseSlotPool
              if not pool.isNil:
                won = pool[].abandonIfGen(slotIdx, slotGen)
                if won:
                  pool[].bumpCancelEpoch()
                  requesterSignal = cast[ptr BrokerSignalShared](pool[].waker(slotIdx))
              providerSignal = `globalBucketsIdent`[i].providerSignal
              break
        if won:
          # Wake the provider so it drops the request (still queued) or cancels
          # the running provider future, and the requester so it resolves now
          # rather than at its timeout.
          fireBrokerSignal(providerSignal)
          fireBrokerSignal(requesterSignal)
        won

  )

  # ── send helpers: prologue + tail ───────────────────────────────────
  let sendAndAwaitIdent = ident("sendAndAwait" & typeDisplayName)
  let sendCancellableIdent = ident("sendCancellable" & typeDisplayName)
  let immediateErrIdent = ident("immediateErr" & typeDisplayName)
  result.add(
    quote do:
      proc `immediateErrIdent`(
          message: string
      ): Future[Result[`payloadType`, string]] {.async: (raises: []).} =
        ## An already-failed response future, so every `requestCancellable`
        ## return path yields the same future type.
        return err(message)

      proc `sendAndAwaitIdent`(
          ring: ptr VyukovMpscRing[uint32],
          slab: ptr PayloadSlab,
          pool: ptr ResponseSlotPool,
          providerSignal: ptr BrokerSignalShared,
          msg: sink `requestMsgName`,
      ): Future[Result[`payloadType`, string]] {.async: (raises: []).} =
        ensureBrokerDispatchStarted()
        let mySignal = getOrInitBrokerSignal()
        let pro = `sendPrologueIdent`(ring, slab, pool, providerSignal, mySignal, msg)
        if pro.error.len > 0:
          return err(pro.error)
        return await `awaitReplyIdent`(pool, pro.slotIdx, pro.slotGen, mySignal)

      proc `sendCancellableIdent`(
          brokerCtx: BrokerContext,
          ring: ptr VyukovMpscRing[uint32],
          slab: ptr PayloadSlab,
          pool: ptr ResponseSlotPool,
          providerSignal: ptr BrokerSignalShared,
          msg: sink `requestMsgName`,
      ): tuple[
        reqId: `requestIdName`,
        respFut: Future[Result[`payloadType`, string]].Raising([]),
      ] =
        ## Synchronous arming, so the id exists before the caller can await.
        ##
        ## The future handed to the caller is one we own the cancel schedule
        ## for, rather than the waiter's own future. Cancelling it — directly,
        ## or indirectly through a chronos combinator that cancels its losers
        ## (`withTimeout`, `one`, `race`) — is routed into the broker's own
        ## cancel path instead of raising `CancelledError` inside a
        ## `raises: []` waiter that has no handler for it.
        ensureBrokerDispatchStarted()
        let mySignal = getOrInitBrokerSignal()
        let pro = `sendPrologueIdent`(ring, slab, pool, providerSignal, mySignal, msg)
        if pro.error.len > 0:
          return (`requestIdName`(0'u64), `immediateErrIdent`(pro.error))
        let reqId = `requestIdName`((uint64(pro.slotIdx) shl 32) or uint64(pro.slotGen))
        let inner = `awaitReplyIdent`(pool, pro.slotIdx, pro.slotGen, mySignal)
        # `Future[T].Raising([])` cannot be constructed without
        # OwnCancelSchedule — chronos static-asserts that a manually created
        # future either raises CancelledError or owns its cancellation.
        let outer = Future[Result[`payloadType`, string]].Raising([]).init(
            "requestCancellable." & `typeNameLit`, {FutureFlag.OwnCancelSchedule}
          )
        let capturedCtx = brokerCtx
        let capturedId = reqId
        let capturedInner = inner
        let capturedOuter = outer
        # Captures ctx and id as *values*, never the pool pointer: this runs
        # later, by which time the provider thread may have freed the pool.
        # Going through cancelById keeps the lock-covered lookup that makes
        # that safe.
        capturedOuter.cancelCallback = proc(udata: pointer) {.gcsafe, raises: [].} =
          discard `cancelByIdIdent`(capturedCtx, capturedId)
        # Single completion point: the waiter always resolves (the request
        # timeout is the backstop), and it is the only thing that completes
        # the caller's future — including when a cancel lost the race and the
        # real response arrived anyway.
        capturedInner.addCallback(
          proc(udata: pointer) {.gcsafe, raises: [].} =
            if not capturedOuter.finished():
              let readRes = catch:
                capturedInner.read()
              if readRes.isOk():
                capturedOuter.complete(readRes.get())
              else:
                capturedOuter.complete(
                  err(
                    Result[`payloadType`, string],
                    "RequestBroker(" & `typeNameLit` & "): recv failed: " &
                      readRes.error.msg,
                  )
                )
        )
        (reqId, capturedOuter)

  )

  # ── blockingRequest helper: prologue + synchronous wait ─────────────
  let blockingWaitIdent = ident("blockingWait" & typeDisplayName)
  let blockingSendAndAwaitIdent = ident("blockingSendAndAwait" & typeDisplayName)
  let blockingSendCancellableIdent = ident("blockingSendCancellable" & typeDisplayName)
  result.add(
    quote do:
      proc `blockingWaitIdent`(
          pool: ptr ResponseSlotPool, slotIdx: uint32, slotGen: uint32
      ): Result[`payloadType`, string] {.gcsafe, raises: [].} =
        # Busy-poll the response slot until ready, cancelled, or timed out.
        let deadline = Moment.now() + `timeoutVarIdent`
        while Moment.now() < deadline:
          if pool[].readyState(slotIdx, slotGen):
            var decoded: Result[`payloadType`, string]
            let payloadPtr = pool[].respDataPtr(slotIdx)
            let payloadSize = pool[].respDataLen(slotIdx)
            let ok =
              try:
                `unmarshalRespIdent`(payloadPtr, payloadSize, decoded)
              except Exception:
                false
            pool[].release(slotIdx, `shardHintIdent`())
            if ok:
              return decoded
            return
              err("RequestBroker(" & `typeNameLit` & "): response unmarshal failed")
          if pool[].isProviderGone(slotIdx, slotGen):
            # Provider cleared mid-request: nothing will answer, and the slot
            # is ours to hand back.
            pool[].release(slotIdx, `shardHintIdent`())
            return err(
              "RequestBroker(" & `typeNameLit` &
                "): provider was cleared while the request was outstanding"
            )
          if pool[].isAbandoned(slotIdx, slotGen):
            # Cancelled from another thread. That CAS won, so the provider owns
            # the release and there is nothing left to wait for.
            return err("RequestBroker(" & `typeNameLit` & "): request cancelled")
          sleep(1)
        # Timeout. Ownership is settled here and now: the provider releases
        # unless it already published the response, in which case the slot is
        # ours. Nothing waits on the provider — a blocking caller that lingered
        # for a late commit would either block past its own deadline or, if it
        # gave up waiting, leak the slot.
        if pool[].giveUpSlot(slotIdx, slotGen) == SlotGiveUp.CallerReleases:
          pool[].release(slotIdx, `shardHintIdent`())
        return err(
          "RequestBroker(" & `typeNameLit` & "): cross-thread request timed out after " &
            $`timeoutVarIdent`
        )

      proc `blockingSendAndAwaitIdent`(
          ring: ptr VyukovMpscRing[uint32],
          slab: ptr PayloadSlab,
          pool: ptr ResponseSlotPool,
          providerSignal: ptr BrokerSignalShared,
          msg: sink `requestMsgName`,
      ): Result[`payloadType`, string] {.gcsafe, raises: [].} =
        # No async loop on this thread, so no waker: the wait below polls.
        let pro = `sendPrologueIdent`(ring, slab, pool, providerSignal, nil, msg)
        if pro.error.len > 0:
          return err(pro.error)
        `blockingWaitIdent`(pool, pro.slotIdx, pro.slotGen)

      proc `blockingSendCancellableIdent`(
          ring: ptr VyukovMpscRing[uint32],
          slab: ptr PayloadSlab,
          pool: ptr ResponseSlotPool,
          providerSignal: ptr BrokerSignalShared,
          msg: sink `requestMsgName`,
          idOut: ptr `requestIdName`,
      ): Result[`payloadType`, string] {.gcsafe, raises: [].} =
        ## The id is published before the wait begins — a blocking caller
        ## cannot hand it out afterwards, so `idOut` must point at storage the
        ## canceller can read. The caller's own frame is alive for the whole
        ## call, which is what makes that pointer safe.
        let pro = `sendPrologueIdent`(ring, slab, pool, providerSignal, nil, msg)
        if pro.error.len > 0:
          if not idOut.isNil:
            idOut[] = `requestIdName`(0'u64)
          return err(pro.error)
        if not idOut.isNil:
          idOut[] = `requestIdName`((uint64(pro.slotIdx) shl 32) or uint64(pro.slotGen))
        `blockingWaitIdent`(pool, pro.slotIdx, pro.slotGen)

  )

  # ── request (zero-arg) ──────────────────────────────────────────────
  if not zeroArgSig.isNil():
    result.add(
      quote do:
        proc request*(
            _: typedesc[`typeIdent`], brokerCtx: BrokerContext
        ): Future[Result[`payloadType`, string]] {.async: (raises: []).} =
          `initProcIdent`()
          var ring: ptr VyukovMpscRing[uint32]
          var slab: ptr PayloadSlab
          var pool: ptr ResponseSlotPool
          var providerSignal: ptr BrokerSignalShared
          var sameThread = false
          let myThreadGen = currentMtThreadGen()
          withLock(`globalLockIdent`):
            for i in 0 ..< `globalBucketCountIdent`:
              if `globalBucketsIdent`[i].brokerCtx == brokerCtx:
                if `globalBucketsIdent`[i].threadId == currentMtThreadId() and
                    `globalBucketsIdent`[i].threadGen == myThreadGen:
                  sameThread = true
                else:
                  ring = `globalBucketsIdent`[i].ring
                  slab = `globalBucketsIdent`[i].slab
                  pool = `globalBucketsIdent`[i].responseSlotPool
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
              await provider()
            if catchedRes.isErr():
              return err(
                "RequestBroker(" & `typeNameLit` & "): provider threw exception: " &
                  catchedRes.error.msg
              )
            return catchedRes.get()
          if ring.isNil:
            return err(
              "RequestBroker(" & `typeNameLit` &
                "): no zero-arg provider registered for broker context " & $brokerCtx
            )
          var msg = `requestMsgName`(requestKind: 0)
          return await `sendAndAwaitIdent`(ring, slab, pool, providerSignal, msg)

        proc request*(
            _: typedesc[`typeIdent`]
        ): Future[Result[`payloadType`, string]] {.async: (raises: []).} =
          return await request(`typeIdent`, DefaultBrokerContext)

    )
  else:
    result.add(
      quote do:
        proc request*(
            _: typedesc[`typeIdent`]
        ): Future[Result[`payloadType`, string]] {.async: (raises: []).} =
          return
            err("RequestBroker(" & `typeNameLit` & "): no zero-arg provider registered")

    )

  # ── blockingRequest (zero-arg) ──────────────────────────────────────
  if not zeroArgSig.isNil():
    result.add(
      quote do:
        proc blockingRequest*(
            _: typedesc[`typeIdent`], brokerCtx: BrokerContext
        ): Result[`payloadType`, string] {.gcsafe, raises: [].} =
          `initProcIdent`()
          var ring: ptr VyukovMpscRing[uint32]
          var slab: ptr PayloadSlab
          var pool: ptr ResponseSlotPool
          var providerSignal: ptr BrokerSignalShared
          var sameThread = false
          let myThreadGen = currentMtThreadGen()
          withLock(`globalLockIdent`):
            for i in 0 ..< `globalBucketCountIdent`:
              if `globalBucketsIdent`[i].brokerCtx == brokerCtx:
                if `globalBucketsIdent`[i].threadId == currentMtThreadId() and
                    `globalBucketsIdent`[i].threadGen == myThreadGen:
                  sameThread = true
                else:
                  ring = `globalBucketsIdent`[i].ring
                  slab = `globalBucketsIdent`[i].slab
                  pool = `globalBucketsIdent`[i].responseSlotPool
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
            return catchedRes.get()
          if ring.isNil:
            return err(
              "RequestBroker(" & `typeNameLit` &
                "): no zero-arg provider registered for broker context " & $brokerCtx
            )
          var msg = `requestMsgName`(requestKind: 0)
          `blockingSendAndAwaitIdent`(ring, slab, pool, providerSignal, msg)

        proc blockingRequest*(
            _: typedesc[`typeIdent`]
        ): Result[`payloadType`, string] {.gcsafe, raises: [].} =
          blockingRequest(`typeIdent`, DefaultBrokerContext)

    )
  else:
    result.add(
      quote do:
        proc blockingRequest*(
            _: typedesc[`typeIdent`]
        ): Result[`payloadType`, string] {.gcsafe, raises: [].} =
          return
            err("RequestBroker(" & `typeNameLit` & "): no zero-arg provider registered")

    )

  # ── request (with-args) ─────────────────────────────────────────────
  if not argSig.isNil():
    let requestParamDefs = cloneParams(argParams)
    let argNameIdents = collectParamNames(requestParamDefs)

    # Build the keyed (ctx-explicit) request proc.
    let reqPragmas = quote:
      {.async: (raises: []).}
    let typedescParam =
      newTree(nnkBracketExpr, ident("typedesc"), copyNimTree(typeIdent))

    var keyedFormalParams = newTree(nnkFormalParams)
    keyedFormalParams.add(copyNimTree(returnType))
    keyedFormalParams.add(
      newTree(nnkIdentDefs, ident("_"), typedescParam, newEmptyNode())
    )
    keyedFormalParams.add(
      newTree(nnkIdentDefs, ident("brokerCtx"), ident("BrokerContext"), newEmptyNode())
    )
    for paramDef in requestParamDefs:
      keyedFormalParams.add(paramDef)

    let providerSym = genSym(nskVar, "provider")
    var providerCall = newCall(providerSym)
    for argName in argNameIdents:
      providerCall.add(argName)

    var msgCtor = newTree(nnkObjConstr, requestMsgName)
    msgCtor.add(newTree(nnkExprColonExpr, ident("requestKind"), newLit(1)))
    for argName in argNameIdents:
      msgCtor.add(newTree(nnkExprColonExpr, argName, argName))

    let keyedBody = quote:
      `initProcIdent`()
      var ring: ptr VyukovMpscRing[uint32]
      var slab: ptr PayloadSlab
      var pool: ptr ResponseSlotPool
      var providerSignal: ptr BrokerSignalShared
      var sameThread = false
      let myThreadGen = currentMtThreadGen()
      withLock(`globalLockIdent`):
        for i in 0 ..< `globalBucketCountIdent`:
          if `globalBucketsIdent`[i].brokerCtx == brokerCtx:
            if `globalBucketsIdent`[i].threadId == currentMtThreadId() and
                `globalBucketsIdent`[i].threadGen == myThreadGen:
              sameThread = true
            else:
              ring = `globalBucketsIdent`[i].ring
              slab = `globalBucketsIdent`[i].slab
              pool = `globalBucketsIdent`[i].responseSlotPool
              providerSignal = `globalBucketsIdent`[i].providerSignal
            break
      if sameThread:
        var `providerSym`: `argProviderName`
        for i in 0 ..< `tvWithArgCtxIdent`.len:
          if `tvWithArgCtxIdent`[i] == brokerCtx:
            `providerSym` = `tvWithArgHandlerIdent`[i]
            break
        if `providerSym`.isNil():
          return err(
            "RequestBroker(" & `typeNameLit` &
              "): no provider registered for input signature"
          )
        let catchedRes = catch:
          await `providerCall`
        if catchedRes.isErr():
          return err(
            "RequestBroker(" & `typeNameLit` & "): provider threw exception: " &
              catchedRes.error.msg
          )
        return catchedRes.get()
      if ring.isNil:
        return err(
          "RequestBroker(" & `typeNameLit` &
            "): no provider registered for broker context " & $brokerCtx
        )
      var msg = `msgCtor`
      return await `sendAndAwaitIdent`(ring, slab, pool, providerSignal, msg)

    result.add(
      newTree(
        nnkProcDef,
        postfix(ident("request"), "*"),
        newEmptyNode(),
        newEmptyNode(),
        keyedFormalParams,
        reqPragmas,
        newEmptyNode(),
        keyedBody,
      )
    )

    # Non-keyed forwarder.
    var nonKeyedFormalParams = newTree(nnkFormalParams)
    nonKeyedFormalParams.add(copyNimTree(returnType))
    nonKeyedFormalParams.add(
      newTree(nnkIdentDefs, ident("_"), typedescParam, newEmptyNode())
    )
    for paramDef in cloneParams(argParams):
      nonKeyedFormalParams.add(paramDef)

    var forwardCall = newCall(ident("request"))
    forwardCall.add(copyNimTree(typeIdent))
    forwardCall.add(ident("DefaultBrokerContext"))
    for argName in argNameIdents:
      forwardCall.add(argName)
    let forwardBody = quote:
      return await `forwardCall`

    result.add(
      newTree(
        nnkProcDef,
        postfix(ident("request"), "*"),
        newEmptyNode(),
        newEmptyNode(),
        nonKeyedFormalParams,
        reqPragmas,
        newEmptyNode(),
        forwardBody,
      )
    )

  # ── blockingRequest (with-args) ─────────────────────────────────────
  if not argSig.isNil():
    let brParamDefs = cloneParams(argParams)
    let brArgNameIdents = collectParamNames(brParamDefs)
    let brPragmas = quote:
      {.gcsafe, raises: [].}
    let typedescParam =
      newTree(nnkBracketExpr, ident("typedesc"), copyNimTree(typeIdent))

    var brKeyedFormalParams = newTree(nnkFormalParams)
    brKeyedFormalParams.add(
      newTree(nnkBracketExpr, ident("Result"), copyNimTree(typeIdent), ident("string"))
    )
    brKeyedFormalParams.add(
      newTree(nnkIdentDefs, ident("_"), typedescParam, newEmptyNode())
    )
    brKeyedFormalParams.add(
      newTree(nnkIdentDefs, ident("brokerCtx"), ident("BrokerContext"), newEmptyNode())
    )
    for paramDef in brParamDefs:
      brKeyedFormalParams.add(paramDef)

    let brProviderSym = genSym(nskVar, "provider")
    var brProviderCall = newCall(brProviderSym)
    for argName in brArgNameIdents:
      brProviderCall.add(argName)

    var brMsgCtor = newTree(nnkObjConstr, requestMsgName)
    brMsgCtor.add(newTree(nnkExprColonExpr, ident("requestKind"), newLit(1)))
    for argName in brArgNameIdents:
      brMsgCtor.add(newTree(nnkExprColonExpr, argName, argName))

    let brKeyedBody = quote:
      `initProcIdent`()
      var ring: ptr VyukovMpscRing[uint32]
      var slab: ptr PayloadSlab
      var pool: ptr ResponseSlotPool
      var providerSignal: ptr BrokerSignalShared
      var sameThread = false
      let myThreadGen = currentMtThreadGen()
      withLock(`globalLockIdent`):
        for i in 0 ..< `globalBucketCountIdent`:
          if `globalBucketsIdent`[i].brokerCtx == brokerCtx:
            if `globalBucketsIdent`[i].threadId == currentMtThreadId() and
                `globalBucketsIdent`[i].threadGen == myThreadGen:
              sameThread = true
            else:
              ring = `globalBucketsIdent`[i].ring
              slab = `globalBucketsIdent`[i].slab
              pool = `globalBucketsIdent`[i].responseSlotPool
              providerSignal = `globalBucketsIdent`[i].providerSignal
            break
      if sameThread:
        var `brProviderSym`: `argProviderName`
        for i in 0 ..< `tvWithArgCtxIdent`.len:
          if `tvWithArgCtxIdent`[i] == brokerCtx:
            `brProviderSym` = `tvWithArgHandlerIdent`[i]
            break
        if `brProviderSym`.isNil():
          return err(
            "RequestBroker(" & `typeNameLit` &
              "): no provider registered for input signature"
          )
        let catchedRes = catch:
          blockingAwait(`brProviderCall`)
        if catchedRes.isErr():
          return err(
            "RequestBroker(" & `typeNameLit` & "): provider threw exception: " &
              catchedRes.error.msg
          )
        return catchedRes.get()
      if ring.isNil:
        return err(
          "RequestBroker(" & `typeNameLit` &
            "): no provider registered for broker context " & $brokerCtx
        )
      var msg = `brMsgCtor`
      `blockingSendAndAwaitIdent`(ring, slab, pool, providerSignal, msg)

    result.add(
      newTree(
        nnkProcDef,
        postfix(ident("blockingRequest"), "*"),
        newEmptyNode(),
        newEmptyNode(),
        brKeyedFormalParams,
        brPragmas,
        newEmptyNode(),
        brKeyedBody,
      )
    )

    # Non-keyed forwarder.
    var brNonKeyedFormalParams = newTree(nnkFormalParams)
    brNonKeyedFormalParams.add(
      newTree(nnkBracketExpr, ident("Result"), copyNimTree(typeIdent), ident("string"))
    )
    brNonKeyedFormalParams.add(
      newTree(nnkIdentDefs, ident("_"), typedescParam, newEmptyNode())
    )
    for paramDef in cloneParams(argParams):
      brNonKeyedFormalParams.add(paramDef)

    var brForwardCall = newCall(ident("blockingRequest"))
    brForwardCall.add(copyNimTree(typeIdent))
    brForwardCall.add(ident("DefaultBrokerContext"))
    for argName in brArgNameIdents:
      brForwardCall.add(argName)
    let brForwardBody = quote:
      `brForwardCall`

    result.add(
      newTree(
        nnkProcDef,
        postfix(ident("blockingRequest"), "*"),
        newEmptyNode(),
        newEmptyNode(),
        brNonKeyedFormalParams,
        brPragmas,
        newEmptyNode(),
        brForwardBody,
      )
    )

  # ── clearProvider ───────────────────────────────────────────────────
  let brokerCtxParam = ident("brokerCtx")
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

  let clearBody = quote:
    `initProcIdent`()
    var ring: ptr VyukovMpscRing[uint32]
    var pool: ptr ResponseSlotPool
    var providerSignal: ptr BrokerSignalShared
    var isProviderThread = false
    let myThreadGen = currentMtThreadGen()
    withLock(`globalLockIdent`):
      var foundIdx = -1
      for i in 0 ..< `globalBucketCountIdent`:
        if `globalBucketsIdent`[i].brokerCtx == `brokerCtxParam`:
          ring = `globalBucketsIdent`[i].ring
          pool = `globalBucketsIdent`[i].responseSlotPool
          providerSignal = `globalBucketsIdent`[i].providerSignal
          isProviderThread = (
            `globalBucketsIdent`[i].threadId == currentMtThreadId() and
            `globalBucketsIdent`[i].threadGen == myThreadGen
          )
          foundIdx = i
          break
      if foundIdx >= 0:
        for i in foundIdx ..< `globalBucketCountIdent` - 1:
          `globalBucketsIdent`[i] = `globalBucketsIdent`[i + 1]
        `globalBucketCountIdent` -= 1
      # Fail outstanding requests fast, under the same lock that publishes the
      # bucket's disappearance. Leaving them to time out means every waiting
      # requester keeps polling this pool for up to its full timeout — and the
      # provider thread frees the pool shortly after this returns.
      if foundIdx >= 0 and not pool.isNil:
        discard pool[].markProviderGone()
    if not pool.isNil:
      # Wake every requester so it resolves now rather than at its next
      # unrelated dispatch tick. Firing a stale or closed signal is a no-op.
      for slotIdx in 0'u32 ..< pool[].capacity:
        let waker = cast[ptr BrokerSignalShared](pool[].waker(slotIdx))
        if not waker.isNil:
          fireBrokerSignal(waker)
    if isProviderThread:
      `tvCleanup`
    if not ring.isNil:
      ring.close()
      fireBrokerSignal(providerSignal)

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

  # ── isProvided ─────────────────────────────────────────────────────
  let isProvidedCtxParam = ident("brokerCtx")
  let isProvidedBody = quote:
    `initProcIdent`()
    withLock(`globalLockIdent`):
      for i in 0 ..< `globalBucketCountIdent`:
        if `globalBucketsIdent`[i].brokerCtx == `isProvidedCtxParam`:
          return true
    return false

  var formalParamsIsProvided = newTree(nnkFormalParams)
  formalParamsIsProvided.add(ident("bool"))
  formalParamsIsProvided.add(
    newTree(
      nnkIdentDefs,
      ident("_"),
      newTree(nnkBracketExpr, ident("typedesc"), copyNimTree(typeIdent)),
      newEmptyNode(),
    )
  )
  formalParamsIsProvided.add(
    newTree(nnkIdentDefs, isProvidedCtxParam, ident("BrokerContext"), newEmptyNode())
  )

  result.add(
    newTree(
      nnkProcDef,
      postfix(ident("isProvided"), "*"),
      newEmptyNode(),
      newEmptyNode(),
      formalParamsIsProvided,
      newEmptyNode(),
      newEmptyNode(),
      isProvidedBody,
    )
  )

  result.add(
    quote do:
      proc isProvided*(_: typedesc[`typeIdent`]): bool =
        isProvided(`typeIdent`, DefaultBrokerContext)

  )

  # ── getCurrentProvider / replaceProvider (owning thread only) ───────
  # MT introspection reads the per-thread threadvar slot, so it MUST be called
  # on the provider's owning thread (the one that ran setProvider). Cross-thread
  # introspection is not supported (the shared bucket holds a ring, not the
  # closure). Distinct zero-arg getter name avoids return-type-only overloads;
  # replaceProvider overloads on the handler proc type.
  if not zeroArgSig.isNil():
    result.add(
      quote do:
        proc getCurrentProviderNoArgs*(
            _: typedesc[`typeIdent`], brokerCtx: BrokerContext
        ): Option[`zeroArgProviderName`] =
          for i in 0 ..< `tvNoArgCtxIdent`.len:
            if `tvNoArgCtxIdent`[i] == brokerCtx:
              return some(`tvNoArgHandlerIdent`[i])
          none(`zeroArgProviderName`)

        proc replaceProvider*(
            _: typedesc[`typeIdent`],
            brokerCtx: BrokerContext,
            handler: `zeroArgProviderName`,
        ): Result[void, string] =
          ## Replace-or-insert on the owning thread; never errors on an existing
          ## entry (unlike setProvider). A new ctx also sets up its bucket.
          `initProcIdent`()
          for i in 0 ..< `tvNoArgCtxIdent`.len:
            if `tvNoArgCtxIdent`[i] == brokerCtx:
              `tvNoArgHandlerIdent`[i] = handler
              return ok()
          `tvNoArgCtxIdent`.add(brokerCtx)
          `tvNoArgHandlerIdent`.add(handler)
          let r = `setupBucketIdent`(brokerCtx)
          if r.isErr():
            `tvNoArgCtxIdent`.setLen(`tvNoArgCtxIdent`.len - 1)
            `tvNoArgHandlerIdent`.setLen(`tvNoArgHandlerIdent`.len - 1)
            return r
          ok()

        template withMockProvider*(
            t: typedesc[`typeIdent`],
            brokerCtx: BrokerContext,
            mock: `zeroArgProviderName`,
            body: untyped,
        ): untyped =
          ## Owning-thread only. Install `mock` for the duration of `body`, then
          ## restore the captured provider (or clear it if none was set).
          let savedMockProvider = getCurrentProviderNoArgs(t, brokerCtx)
          discard replaceProvider(t, brokerCtx, mock)
          try:
            body
          finally:
            if savedMockProvider.isSome:
              discard replaceProvider(t, brokerCtx, savedMockProvider.get)
            else:
              clearProvider(t, brokerCtx)

    )
  if not argSig.isNil():
    result.add(
      quote do:
        proc getCurrentProvider*(
            _: typedesc[`typeIdent`], brokerCtx: BrokerContext
        ): Option[`argProviderName`] =
          for i in 0 ..< `tvWithArgCtxIdent`.len:
            if `tvWithArgCtxIdent`[i] == brokerCtx:
              return some(`tvWithArgHandlerIdent`[i])
          none(`argProviderName`)

        proc replaceProvider*(
            _: typedesc[`typeIdent`],
            brokerCtx: BrokerContext,
            handler: `argProviderName`,
        ): Result[void, string] =
          ## Replace-or-insert on the owning thread; never errors on an existing
          ## entry (unlike setProvider). A new ctx also sets up its bucket.
          `initProcIdent`()
          for i in 0 ..< `tvWithArgCtxIdent`.len:
            if `tvWithArgCtxIdent`[i] == brokerCtx:
              `tvWithArgHandlerIdent`[i] = handler
              return ok()
          `tvWithArgCtxIdent`.add(brokerCtx)
          `tvWithArgHandlerIdent`.add(handler)
          let r = `setupBucketIdent`(brokerCtx)
          if r.isErr():
            `tvWithArgCtxIdent`.setLen(`tvWithArgCtxIdent`.len - 1)
            `tvWithArgHandlerIdent`.setLen(`tvWithArgHandlerIdent`.len - 1)
            return r
          ok()

        template withMockProvider*(
            t: typedesc[`typeIdent`],
            brokerCtx: BrokerContext,
            mock: `argProviderName`,
            body: untyped,
        ): untyped =
          ## Owning-thread only. Install `mock` for the duration of `body`, then
          ## restore the captured provider (or clear it if none was set).
          let savedMockProvider = getCurrentProvider(t, brokerCtx)
          discard replaceProvider(t, brokerCtx, mock)
          try:
            body
          finally:
            if savedMockProvider.isSome:
              discard replaceProvider(t, brokerCtx, savedMockProvider.get)
            else:
              clearProvider(t, brokerCtx)

    )

  # ── bind / rebind provider sugar (issue #42) ──────────────────────
  # Sugar over setProvider / replaceProvider for class-method providers. MT is
  # always async; the trampoline carries the provider proc type's `{.async.}`
  # pragma. Owning-thread semantics of setProvider/replaceProvider are unchanged
  # (the sugar only synthesises the closure the user would write by hand).
  block:
    let providerPragma = procTyPragma(makeProcType(returnType, @[]))
    var slots: seq[BindSlot] = @[]
    if not argSig.isNil():
      slots.add(
        BindSlot(
          params: cloneParams(argParams),
          returnType: copyNimTree(returnType),
          pragma: providerPragma,
        )
      )
    if not zeroArgSig.isNil():
      slots.add(
        BindSlot(
          params: @[], returnType: copyNimTree(returnType), pragma: providerPragma
        )
      )
    result.add(
      buildBindTemplates(
        typeIdent, "setProvider", "bindProvider", slots, awaitCall = true
      )
    )
    result.add(
      buildBindTemplates(
        typeIdent, "replaceProvider", "rebindProvider", slots, awaitCall = true
      )
    )

  # ── provideIt / reprovideIt body sugar ─────────────────────────────
  # Same surface as the single-thread lane (see request_broker.nim). Owning-
  # thread semantics of setProvider/replaceProvider are unchanged — the sugar
  # only synthesises the closure the user would write by hand, and
  # `providerBody` rejects bodies that could silently fall through to err("").
  block:
    let providerPragma = procTyPragma(makeProcType(returnType, @[]))
    let dualSlot = (not argSig.isNil()) and (not zeroArgSig.isNil())
    if not argSig.isNil():
      let slot = BindSlot(
        params: cloneParams(argParams),
        returnType: copyNimTree(returnType),
        pragma: providerPragma,
      )
      result.add(buildProvideTemplates(typeIdent, "setProvider", "provideIt", slot))
      result.add(
        buildProvideTemplates(typeIdent, "replaceProvider", "reprovideIt", slot)
      )
    if not zeroArgSig.isNil():
      let slot = BindSlot(
        params: @[], returnType: copyNimTree(returnType), pragma: providerPragma
      )
      let provideName = if dualSlot: "provideItNoArgs" else: "provideIt"
      let reprovideName = if dualSlot: "reprovideItNoArgs" else: "reprovideIt"
      result.add(buildProvideTemplates(typeIdent, "setProvider", provideName, slot))
      result.add(
        buildProvideTemplates(typeIdent, "replaceProvider", reprovideName, slot)
      )

  # ── cancellation surface ────────────────────────────────────────────
  # Emitted last: these call `request` / the send helpers, so they must come
  # after them in the generated stmt list.
  #
  # `cancel` performs its CAS **while holding the bucket lock**. That is what
  # makes it free of use-after-free: `clearProvider` removes the bucket under
  # the same lock *before* closing the ring, and the pool is only queued for
  # free once the provider's poll fn observes the closed ring. So a bucket
  # found under the lock cannot have had its pool freed; a bucket that is gone
  # means the request is unreachable and `cancel` reports false without
  # touching any pool memory.
  let cancelReturnType = quote:
    tuple[
      reqId: `requestIdName`, respFut: Future[Result[`payloadType`, string]].Raising([])
    ]

  result.add(
    quote do:
      proc cancel*(
          _: typedesc[`typeIdent`], brokerCtx: BrokerContext, id: `requestIdName`
      ): bool =
        ## Cancel an outstanding cross-thread request. Callable from any
        ## thread. True means the cancellation was published — the request
        ## will resolve with "request cancelled" and its provider, if already
        ## running, is cancelled. False means there was nothing to cancel: the
        ## response was already being written, or the id is stale.
        `cancelByIdIdent`(brokerCtx, id)

      proc cancel*(_: typedesc[`typeIdent`], id: `requestIdName`): bool =
        `cancelByIdIdent`(DefaultBrokerContext, id)

  )

  if not zeroArgSig.isNil():
    result.add(
      quote do:
        proc requestCancellable*(
            _: typedesc[`typeIdent`], brokerCtx: BrokerContext
        ): `cancelReturnType` =
          ## Like `request`, but also returns an id that any thread may pass
          ## to `cancel`. The id is produced before this proc returns, so it
          ## is always usable by the time the caller holds it.
          `initProcIdent`()
          var ring: ptr VyukovMpscRing[uint32]
          var slab: ptr PayloadSlab
          var pool: ptr ResponseSlotPool
          var providerSignal: ptr BrokerSignalShared
          var sameThread = false
          let myThreadGen = currentMtThreadGen()
          withLock(`globalLockIdent`):
            for i in 0 ..< `globalBucketCountIdent`:
              if `globalBucketsIdent`[i].brokerCtx == brokerCtx:
                if `globalBucketsIdent`[i].threadId == currentMtThreadId() and
                    `globalBucketsIdent`[i].threadGen == myThreadGen:
                  sameThread = true
                else:
                  ring = `globalBucketsIdent`[i].ring
                  slab = `globalBucketsIdent`[i].slab
                  pool = `globalBucketsIdent`[i].responseSlotPool
                  providerSignal = `globalBucketsIdent`[i].providerSignal
                break
          if sameThread:
            # Same-thread requests call the provider directly: no queue, no
            # response slot, nothing to cancel.
            return (`requestIdName`(0'u64), request(`typeIdent`, brokerCtx))
          if ring.isNil:
            return (
              `requestIdName`(0'u64),
              `immediateErrIdent`(
                "RequestBroker(" & `typeNameLit` &
                  "): no zero-arg provider registered for broker context " & $brokerCtx
              ),
            )
          var msg = `requestMsgName`(requestKind: 0)
          `sendCancellableIdent`(brokerCtx, ring, slab, pool, providerSignal, msg)

        proc requestCancellable*(_: typedesc[`typeIdent`]): `cancelReturnType` =
          requestCancellable(`typeIdent`, DefaultBrokerContext)

        proc blockingRequestCancellable*(
            _: typedesc[`typeIdent`],
            brokerCtx: BrokerContext,
            idOut: ptr `requestIdName`,
        ): Result[`payloadType`, string] {.gcsafe, raises: [].} =
          ## Blocking variant. `idOut` is written before the wait begins —
          ## point it at storage another thread can read, since this caller is
          ## blocked and cannot publish the id itself.
          `initProcIdent`()
          if not idOut.isNil:
            idOut[] = `requestIdName`(0'u64)
          var ring: ptr VyukovMpscRing[uint32]
          var slab: ptr PayloadSlab
          var pool: ptr ResponseSlotPool
          var providerSignal: ptr BrokerSignalShared
          var sameThread = false
          let myThreadGen = currentMtThreadGen()
          withLock(`globalLockIdent`):
            for i in 0 ..< `globalBucketCountIdent`:
              if `globalBucketsIdent`[i].brokerCtx == brokerCtx:
                if `globalBucketsIdent`[i].threadId == currentMtThreadId() and
                    `globalBucketsIdent`[i].threadGen == myThreadGen:
                  sameThread = true
                else:
                  ring = `globalBucketsIdent`[i].ring
                  slab = `globalBucketsIdent`[i].slab
                  pool = `globalBucketsIdent`[i].responseSlotPool
                  providerSignal = `globalBucketsIdent`[i].providerSignal
                break
          if sameThread or ring.isNil:
            return blockingRequest(`typeIdent`, brokerCtx)
          var msg = `requestMsgName`(requestKind: 0)
          `blockingSendCancellableIdent`(ring, slab, pool, providerSignal, msg, idOut)

        proc blockingRequestCancellable*(
            _: typedesc[`typeIdent`], idOut: ptr `requestIdName`
        ): Result[`payloadType`, string] {.gcsafe, raises: [].} =
          blockingRequestCancellable(`typeIdent`, DefaultBrokerContext, idOut)

    )

  if not argSig.isNil():
    let ccParamDefs = cloneParams(argParams)
    let ccArgNames = collectParamNames(ccParamDefs)
    let ccTypedescParam =
      newTree(nnkBracketExpr, ident("typedesc"), copyNimTree(typeIdent))

    var ccMsgCtor = newTree(nnkObjConstr, requestMsgName)
    ccMsgCtor.add(newTree(nnkExprColonExpr, ident("requestKind"), newLit(1)))
    for argName in ccArgNames:
      ccMsgCtor.add(newTree(nnkExprColonExpr, argName, argName))

    var ccForwardCall = newCall(ident("request"))
    ccForwardCall.add(copyNimTree(typeIdent))
    ccForwardCall.add(ident("brokerCtx"))
    for argName in ccArgNames:
      ccForwardCall.add(argName)

    let ccBody = quote:
      `initProcIdent`()
      var ring: ptr VyukovMpscRing[uint32]
      var slab: ptr PayloadSlab
      var pool: ptr ResponseSlotPool
      var providerSignal: ptr BrokerSignalShared
      var sameThread = false
      let myThreadGen = currentMtThreadGen()
      withLock(`globalLockIdent`):
        for i in 0 ..< `globalBucketCountIdent`:
          if `globalBucketsIdent`[i].brokerCtx == brokerCtx:
            if `globalBucketsIdent`[i].threadId == currentMtThreadId() and
                `globalBucketsIdent`[i].threadGen == myThreadGen:
              sameThread = true
            else:
              ring = `globalBucketsIdent`[i].ring
              slab = `globalBucketsIdent`[i].slab
              pool = `globalBucketsIdent`[i].responseSlotPool
              providerSignal = `globalBucketsIdent`[i].providerSignal
            break
      if sameThread:
        return (`requestIdName`(0'u64), `ccForwardCall`)
      if ring.isNil:
        return (
          `requestIdName`(0'u64),
          `immediateErrIdent`(
            "RequestBroker(" & `typeNameLit` &
              "): no provider registered for broker context " & $brokerCtx
          ),
        )
      var msg = `ccMsgCtor`
      return `sendCancellableIdent`(brokerCtx, ring, slab, pool, providerSignal, msg)

    var ccFormalParams = newTree(nnkFormalParams)
    ccFormalParams.add(copyNimTree(cancelReturnType))
    ccFormalParams.add(
      newTree(nnkIdentDefs, ident("_"), copyNimTree(ccTypedescParam), newEmptyNode())
    )
    ccFormalParams.add(
      newTree(nnkIdentDefs, ident("brokerCtx"), ident("BrokerContext"), newEmptyNode())
    )
    for paramDef in cloneParams(argParams):
      ccFormalParams.add(paramDef)

    result.add(
      newTree(
        nnkProcDef,
        postfix(ident("requestCancellable"), "*"),
        newEmptyNode(),
        newEmptyNode(),
        ccFormalParams,
        newEmptyNode(),
        newEmptyNode(),
        ccBody,
      )
    )

    # Non-keyed forwarder.
    var ccNonKeyedParams = newTree(nnkFormalParams)
    ccNonKeyedParams.add(copyNimTree(cancelReturnType))
    ccNonKeyedParams.add(
      newTree(nnkIdentDefs, ident("_"), copyNimTree(ccTypedescParam), newEmptyNode())
    )
    for paramDef in cloneParams(argParams):
      ccNonKeyedParams.add(paramDef)

    var ccNonKeyedCall = newCall(ident("requestCancellable"))
    ccNonKeyedCall.add(copyNimTree(typeIdent))
    ccNonKeyedCall.add(ident("DefaultBrokerContext"))
    for argName in ccArgNames:
      ccNonKeyedCall.add(argName)

    result.add(
      newTree(
        nnkProcDef,
        postfix(ident("requestCancellable"), "*"),
        newEmptyNode(),
        newEmptyNode(),
        ccNonKeyedParams,
        newEmptyNode(),
        newEmptyNode(),
        newStmtList(newTree(nnkReturnStmt, ccNonKeyedCall)),
      )
    )

    # Blocking cancellable variant.
    var bcForwardCall = newCall(ident("blockingRequest"))
    bcForwardCall.add(copyNimTree(typeIdent))
    bcForwardCall.add(ident("brokerCtx"))
    for argName in ccArgNames:
      bcForwardCall.add(argName)

    let bcBody = quote:
      `initProcIdent`()
      if not idOut.isNil:
        idOut[] = `requestIdName`(0'u64)
      var ring: ptr VyukovMpscRing[uint32]
      var slab: ptr PayloadSlab
      var pool: ptr ResponseSlotPool
      var providerSignal: ptr BrokerSignalShared
      var sameThread = false
      let myThreadGen = currentMtThreadGen()
      withLock(`globalLockIdent`):
        for i in 0 ..< `globalBucketCountIdent`:
          if `globalBucketsIdent`[i].brokerCtx == brokerCtx:
            if `globalBucketsIdent`[i].threadId == currentMtThreadId() and
                `globalBucketsIdent`[i].threadGen == myThreadGen:
              sameThread = true
            else:
              ring = `globalBucketsIdent`[i].ring
              slab = `globalBucketsIdent`[i].slab
              pool = `globalBucketsIdent`[i].responseSlotPool
              providerSignal = `globalBucketsIdent`[i].providerSignal
            break
      if sameThread or ring.isNil:
        return `bcForwardCall`
      var msg = `ccMsgCtor`
      return
        `blockingSendCancellableIdent`(ring, slab, pool, providerSignal, msg, idOut)

    let bcPragmas = quote:
      {.gcsafe, raises: [].}

    var bcFormalParams = newTree(nnkFormalParams)
    bcFormalParams.add(
      newTree(
        nnkBracketExpr, ident("Result"), copyNimTree(payloadType), ident("string")
      )
    )
    bcFormalParams.add(
      newTree(nnkIdentDefs, ident("_"), copyNimTree(ccTypedescParam), newEmptyNode())
    )
    bcFormalParams.add(
      newTree(nnkIdentDefs, ident("brokerCtx"), ident("BrokerContext"), newEmptyNode())
    )
    for paramDef in cloneParams(argParams):
      bcFormalParams.add(paramDef)
    bcFormalParams.add(
      newTree(
        nnkIdentDefs,
        ident("idOut"),
        newTree(nnkPtrTy, copyNimTree(requestIdName)),
        newEmptyNode(),
      )
    )

    result.add(
      newTree(
        nnkProcDef,
        postfix(ident("blockingRequestCancellable"), "*"),
        newEmptyNode(),
        newEmptyNode(),
        bcFormalParams,
        bcPragmas,
        newEmptyNode(),
        bcBody,
      )
    )

    var bcNonKeyedParams = newTree(nnkFormalParams)
    bcNonKeyedParams.add(
      newTree(
        nnkBracketExpr, ident("Result"), copyNimTree(payloadType), ident("string")
      )
    )
    bcNonKeyedParams.add(
      newTree(nnkIdentDefs, ident("_"), copyNimTree(ccTypedescParam), newEmptyNode())
    )
    for paramDef in cloneParams(argParams):
      bcNonKeyedParams.add(paramDef)
    bcNonKeyedParams.add(
      newTree(
        nnkIdentDefs,
        ident("idOut"),
        newTree(nnkPtrTy, copyNimTree(requestIdName)),
        newEmptyNode(),
      )
    )

    var bcNonKeyedCall = newCall(ident("blockingRequestCancellable"))
    bcNonKeyedCall.add(copyNimTree(typeIdent))
    bcNonKeyedCall.add(ident("DefaultBrokerContext"))
    for argName in ccArgNames:
      bcNonKeyedCall.add(argName)
    bcNonKeyedCall.add(ident("idOut"))

    result.add(
      newTree(
        nnkProcDef,
        postfix(ident("blockingRequestCancellable"), "*"),
        newEmptyNode(),
        newEmptyNode(),
        bcNonKeyedParams,
        copyNimTree(bcPragmas),
        newEmptyNode(),
        newStmtList(newTree(nnkReturnStmt, bcNonKeyedCall)),
      )
    )

  when defined(brokerDebug):
    writeBrokerDebug("RequestBrokerMt", typeDisplayName, result)
    when defined(brokerDebugStdout):
      echo result.repr

  return result

{.pop.}
