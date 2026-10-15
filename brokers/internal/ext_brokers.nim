## EXTAPI broker codegen: `RequestBroker(EXTAPI[plugin], …)`.
##
## Lowering (doc/design/EXTAPI_PLAN.md §5.8):
## - the public broker is an ordinary MT RequestBroker — every MT verb stays
##   available, so a Nim implementation is just `setProvider` / `provideIt`;
## - per signature slot a generated forwarder `T.extProvider(ctx)` serves a
##   call from the foreign source registered for that wire name;
## - per slot `install` / `uninstall` procs let the bridge auto-wire the
##   forwarder into the public slot when a plugin provides the name;
## - a compile-time entry in `gExtEntries` that `registerExtPlugin` collects.

{.push raises: [].}

import std/[macros, strutils]
import
  ./helper/broker_utils,
  ./mt_request_broker,
  ./mt_event_broker,
  ./mt_signal_broker,
  ./mt_config,
  ./api_cbor_codec,
  ./ext_runtime,
  ./broker_debug

export mt_request_broker, mt_config, api_cbor_codec, ext_runtime

type ExtEntryCT* = object
  plugin*: string
  wireName*: string
  kind*: ExtNameKind
  typeName*: string ## dispatch tag type; dual-slot siblings share it
  installName*: string
  uninstallName*: string
  emitName*: string
  tunnelName*: string ## ExtTunnel adapter proc for this name
  nameIdxVar*: string
  pluginIdxVar*: string
  dispatch*: string ## "" = the plugin default
  workers*: int ## n of `workers(n)`, 0 otherwise
  autoWire*: string ## "" = the plugin default, else "true" / "false"
  args*: seq[(string, string)] ## (name, Nim type) of the request arguments
  payloadType*: string ## response / event / signal value type
  payloadFields*: seq[(string, string)] ## inline object fields of the payload

var gExtEntries* {.compileTime.}: seq[ExtEntryCT]

const extOnlyKwargs = ["dispatch", "autoWire", "importc", "dynlib", "importLib"]

proc splitExtKwargs*(
    kwargs: seq[NimNode]
): tuple[mt: seq[NimNode], ext: seq[NimNode]] {.compileTime.} =
  for kw in kwargs:
    if kw.kind == nnkExprEqExpr and kw[0].kind == nnkIdent and $kw[0] in extOnlyKwargs:
      result.ext.add(kw)
    else:
      result.mt.add(kw)

proc parseDispatch*(v: NimNode): tuple[name: string, workers: int] {.compileTime.} =
  ## `bridge` | `inplace` | `workers(n)` (n ≥ 1).
  let s = (if v.kind in {nnkCall, nnkCommand}: $v[0]
  else: $v).toLowerAscii()
  case s
  of "bridge", "inplace":
    if v.kind in {nnkCall, nnkCommand}:
      error("EXTAPI dispatch `" & s & "` takes no argument", v)
    (s, 0)
  of "workers":
    if v.kind notin {nnkCall, nnkCommand} or v.len != 2 or v[1].kind != nnkIntLit or
        v[1].intVal < 1:
      error("EXTAPI dispatch `workers(n)` needs an integer literal n ≥ 1", v)
    (s, int(v[1].intVal))
  else:
    error("EXTAPI dispatch must be `bridge`, `workers(n)` or `inplace`", v)
    ("", 0)

proc parseBoolLit*(v: NimNode, what: string): string {.compileTime.} =
  if v.kind == nnkIdent and ($v == "true" or $v == "false"):
    return $v
  error(what & " expects `true` or `false`", v)

proc extDispatchArg(
    ext: seq[NimNode]
): tuple[name: string, workers: int, autoWire: string] {.compileTime.} =
  for kw in ext:
    if kw[0].eqIdent("dispatch"):
      let d = parseDispatch(kw[1])
      result.name = d.name
      result.workers = d.workers
    elif kw[0].eqIdent("autoWire"):
      result.autoWire = parseBoolLit(kw[1], "autoWire")
    elif kw[0].eqIdent("importc") or kw[0].eqIdent("dynlib") or
        kw[0].eqIdent("importLib"):
      error("EXTAPI kwarg `" & $kw[0] & "` is not implemented yet", kw)

proc pluginNameOf*(modeNode: NimNode): string {.compileTime.} =
  ## `EXTAPI[storage]` → "storage".
  if modeNode.kind != nnkBracketExpr or modeNode.len != 2 or modeNode[1].kind != nnkIdent:
    error("EXTAPI expects exactly one plugin identifier: `EXTAPI[<plugin>]`", modeNode)
  $modeNode[1]

proc isExtMode*(modeNode: NimNode): bool {.compileTime.} =
  modeNode.kind == nnkBracketExpr and modeNode.len >= 1 and modeNode[0].kind == nnkIdent and
    modeNode[0].eqIdent("EXTAPI")

proc fieldPairs(parsed: ParsedBrokerType): seq[(string, string)] {.compileTime.} =
  for i in 0 ..< parsed.fieldNames.len:
    var n = $parsed.fieldNames[i]
    if n.endsWith("*"):
      n.setLen(n.len - 1)
    result.add((n, parsed.fieldTypes[i].repr.strip()))

proc stampLineInfo(n, src: NimNode) {.compileTime.} =
  ## parseStmt nodes carry fileless line info; chronos' async transform
  ## resolves source locations and dies with OSError on them. Copy a real
  ## node's line info onto the whole generated tree.
  n.copyLineInfo(src)
  for c in n:
    stampLineInfo(c, src)

proc paramNames(argParams: seq[NimNode]): seq[string] {.compileTime.} =
  for paramDefs in argParams:
    let lastIdx = paramDefs.len - 1
    for nameIdx in 0 ..< lastIdx - 1:
      let n = paramDefs[nameIdx]
      result.add(
        case n.kind
        of nnkPostfix:
          $n[1]
        of nnkPragmaExpr:
          $n[0]
        else:
          $n
      )

proc paramDeclSrc(argParams: seq[NimNode]): string {.compileTime.} =
  var parts: seq[string]
  for paramDefs in argParams:
    let lastIdx = paramDefs.len - 1
    let t = paramDefs[lastIdx - 1].repr.strip()
    for nameIdx in 0 ..< lastIdx - 1:
      let n = paramDefs[nameIdx]
      let nm =
        case n.kind
        of nnkPostfix:
          $n[1]
        of nnkPragmaExpr:
          $n[0]
        else:
          $n
      parts.add(nm & ": " & t)
  parts.join(", ")

proc generateExtRequestBroker*(
    modeNode: NimNode, kwargs: seq[NimNode], body: NimNode
): NimNode {.raises: [ValueError].} =
  let plugin = pluginNameOf(modeNode)
  let (mtKw, extKw) = splitExtKwargs(kwargs)
  var cfg = parseMtReqKwargs(mtKw)
  result = newStmtList()
  # 1. The public broker: a plain MT RequestBroker. Under the FFI flag it gets
  #    the inplace hook: the effective dispatch is only known once
  #    registerExtPlugin applies the plugin default, so the hook checks it at
  #    runtime (an array read; the source table is consulted only for
  #    `inplace` names).
  # Parsed afresh rather than copied: a `let` copy of an object in the
  # compile-time VM can alias the original, and the lane must not get the hook.
  let laneCfg = parseMtReqKwargs(mtKw)
  when defined(BrokerFfiApi):
    cfg.extInplaceHook = true
  result.add(generateMtRequestBroker(copyNimTree(body), cfg))
  when not defined(BrokerFfiApi):
    # Without the FFI flag EXTAPI degrades to `(mt)`: callable, mockable,
    # just not bindable from foreign code (§4).
    discard extKw
    return
  else:
    let dispatch = extDispatchArg(extKw)

    # 2. Classify the body exactly like the (API) lane does.
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

    var typeIdent, payloadType: NimNode
    var isVoid = false
    var payloadFieldPairs: seq[(string, string)]
    var zeroPresent, argPresent = false
    var argParams: seq[NimNode]
    var zeroSuffix, argSuffix = ""
    if not isSugar:
      let parsed = parseSingleTypeDef(
        body, "RequestBroker", allowRefToNonObject = true, collectFieldInfo = true
      )
      typeIdent = parsed.typeIdent
      payloadType = copyNimTree(typeIdent)
      isVoid = parsed.isVoid
      payloadFieldPairs = fieldPairs(parsed)
      var zeroName, argName = ""
      for stmt in body:
        if stmt.kind != nnkProcDef:
          continue
        let nm = (if stmt[0].kind == nnkPostfix: stmt[0][1]
        else: stmt[0])
        if stmt.params.len - 1 == 0:
          zeroPresent = true
          zeroName = $nm
        else:
          argPresent = true
          argName = $nm
          for idx in 1 ..< stmt.params.len:
            argParams.add(copyNimTree(stmt.params[idx]))
      proc legacySuffix(sigName: string): string =
        if sigName.len <= "signature".len:
          return ""
        toSnakeCase(sigName["signature".len .. ^1])

      if zeroPresent and argPresent:
        let zs = legacySuffix(zeroName)
        zeroSuffix = (if zs.len > 0: "_" & zs else: "_zero")
        let asfx = legacySuffix(argName)
        argSuffix = (if asfx.len > 0: "_" & asfx else: "_args")
      if not zeroPresent and not argPresent:
        zeroPresent = true
    else:
      let sg = parseRequestSugar(body, "RequestBroker", async = true)
      typeIdent = sg.typeIdent
      payloadType = sg.payloadType
      isVoid = sg.parsed.isVoid
      payloadFieldPairs = fieldPairs(sg.parsed)
      zeroPresent = not sg.zeroArgProc.isNil
      argPresent = not sg.argProc.isNil
      argParams = sg.argParams
      if zeroPresent and argPresent:
        argSuffix = "_arg"

    let typeName = sanitizeIdentName(typeIdent)
    let wireBase = toSnakeCase(typeName)
    let payloadSrc = (if isVoid: "void" else: payloadType.repr.strip())
    let pluginIdxVar = "gExtPluginIdx_" & typeName
    let dual = zeroPresent and argPresent
    let laneType = typeName & "ExtLane"
    let resTy = "Result[" & payloadSrc & ", string]"
    let zeroIdxVar = "gExtNameIdx_" & typeName & "_zero"
    let argIdxVar = "gExtNameIdx_" & typeName & "_arg"

    # 2. The hidden lane: a raw-CBOR MT broker the bridge provides while any
    #    slot of this broker is provided by a plugin. Off-bridge forwarders
    #    reach the foreign source through it (EXTAPI_PLAN §5.8).
    let laneBody = parseStmt(
      "type " & laneType & "* = object\n" & "  payload*: seq[byte]\n" &
        "proc signature*(slot: int32, req: seq[byte]): Future[Result[" & laneType &
        ", string]] {.async.}\n"
    )
    stampLineInfo(laneBody, modeNode)
    result.add(generateMtRequestBroker(laneBody, laneCfg))

    var src =
      "var " & pluginIdxVar & "* {.global.}: int = -1\n" & "var " & zeroIdxVar &
      "* {.global.}: int = -1\n" & "var " & argIdxVar & "* {.global.}: int = -1\n"
    # Reply decoding, shared by every path.
    src.add(
      "proc extDecode_" & typeName & "(b: seq[byte]): " & resTy &
        " {.gcsafe, raises: [].} =\n"
    )
    if isVoid:
      src.add("  ok()\n")
    else:
      src.add(
        "  let d = cborDecode(b, " & payloadSrc & ")\n" & "  if d.isErr:\n" &
          "    return err(\"EXTAPI: reply decode failed: \" & d.error)\n" &
          "  ok(d.value)\n"
      )
    # The lane provider (installed on the bridge).
    src.add(
      "proc extLaneProvider*(_: typedesc[" & typeName & "], ctx: BrokerContext): " &
        laneType & "ProviderWithArgs =\n" & "  var pIdx, nZero, nArg: int\n" &
        "  {.cast(gcsafe).}:\n" & "    pIdx = " & pluginIdxVar & "\n" & "    nZero = " &
        zeroIdxVar & "\n" & "    nArg = " & argIdxVar & "\n" &
        "  result = proc(slot: int32, req: seq[byte]): Future[Result[" & laneType &
        ", string]] {.async.} =\n" & "    var tmo: Duration\n" &
        "    {.cast(gcsafe).}:\n" & "      tmo = g" & typeName & "MtTimeout\n" &
        "    let r = await extCall(pIdx, (if slot == 0: nZero else: nArg), ctx, req, tmo)\n" &
        "    if r.isErr:\n" & "      return err(r.error)\n" & "    return ok(" & laneType &
        "(payload: r.value))\n"
    )

    proc emitSlot(tag: string, slotLit: int, wireName: string, params: seq[NimNode]) =
      let nameIdxVar = (if tag == "zero": zeroIdxVar else: argIdxVar)
      let providerType =
        typeName & (if params.len == 0: "ProviderNoArgs" else: "ProviderWithArgs")
      let sfx = (if params.len == 0 and dual: "NoArgs" else: "")
      let hookSfx = (if params.len == 0: "NoArgs" else: "Args")
      let decl = paramDeclSrc(params)
      let names = paramNames(params)
      let callArgs = names.join(", ")
      var encExpr: string
      if params.len == 0:
        encExpr = "Result[seq[byte], string].ok(newSeq[byte]())"
      else:
        let argsType = typeName & "ExtArgs" & tag
        src.add("type " & argsType & "* = object\n")
        for p in params:
          let lastIdx = p.len - 1
          let t = p[lastIdx - 1].repr.strip()
          for nm in paramNames(@[p]):
            src.add("  " & nm & "*: " & t & "\n")
        var ctor = argsType & "("
        for i, n in names:
          if i > 0:
            ctor.add(", ")
          ctor.add(n & ": " & n)
        ctor.add(")")
        encExpr = "cborEncode(" & ctor & ")"
      proc idxRead(ctxName: string): string =
        "  var pIdx, nIdx: int\n" & "  {.cast(gcsafe).}:\n" & "    pIdx = " &
          pluginIdxVar & "\n" & "    nIdx = " & nameIdxVar & "\n"

      # Forwarder: serves one call from the external source, from any thread.
      src.add(
        "proc extProvider" & sfx & "*(_: typedesc[" & typeName &
          "], ctx: BrokerContext): " & providerType & " =\n" & idxRead("ctx") &
          "  result = proc(" & decl & "): Future[" & resTy & "] {.async.} =\n" &
          "    let enc = " & encExpr & "\n" & "    if enc.isErr:\n" &
          "      return err(\"EXTAPI: request encode failed: \" & enc.error)\n" &
          "    var r: Result[seq[byte], string]\n" &
          "    if extNameDispatch(pIdx, nIdx) == edInplace:\n" &
          "      r = extCallInplace(pIdx, nIdx, ctx, enc.value)\n" &
          "    elif extOnBridge():\n" & "      var tmo: Duration\n" &
          "      {.cast(gcsafe).}:\n" & "        tmo = g" & typeName & "MtTimeout\n" &
          "      r = await extCall(pIdx, nIdx, ctx, enc.value, tmo)\n" & "    else:\n" &
          "      {.cast(gcsafe).}:\n" & "        g" & laneType & "MtTimeout = g" &
          typeName & "MtTimeout + chronos.seconds(1)\n" &
          "      let (laneId, laneFut) = " & laneType & ".requestCancellable(ctx, " &
          $slotLit & "'i32, enc.value)\n" & "      try:\n" &
          "        let lr = await laneFut\n" & "        if lr.isOk:\n" &
          "          r = Result[seq[byte], string].ok(lr.value.payload)\n" &
          "        else:\n" & "          r = Result[seq[byte], string].err(lr.error)\n" &
          "      except CancelledError as e:\n" & "        discard " & laneType &
          ".cancel(ctx, laneId)\n" & "        raise e\n" & "    if r.isErr:\n" &
          "      return err(r.error)\n" & "    return extDecode_" & typeName &
          "(r.value)\n"
      )
      # Fallback: the external source if one is provided, else the Nim impl —
      # decided per call.
      src.add(
        "proc extFallback" & sfx & "*(_: typedesc[" & typeName &
          "], ctx: BrokerContext, nimImpl: " & providerType & "): " & providerType &
          " =\n" & "  let fwd = " & typeName & ".extProvider" & sfx & "(ctx)\n" &
          idxRead("ctx") & "  result = proc(" & decl & "): Future[" & resTy &
          "] {.async.} =\n" & "    if extAvailable(pIdx, nIdx, ctx):\n" &
          "      return await fwd(" & callArgs & ")\n" & "    return await nimImpl(" &
          callArgs & ")\n"
      )
      src.add(
        "proc extAvailable" & sfx & "*(_: typedesc[" & typeName &
          "], ctx: BrokerContext): bool =\n" & idxRead("ctx") &
          "  extAvailable(pIdx, nIdx, ctx)\n"
      )
      # Inplace hooks, forward-declared by the MT generator
      # (mt_request_broker.addExtInplaceHooks).
      let hookParams = (if decl.len > 0: ", " & decl else: "")
      src.add(
        "proc " & typeName & "ExtInplaceActive" & hookSfx &
          "(brokerCtx: BrokerContext): bool {.gcsafe, raises: [].} =\n" &
          idxRead("brokerCtx") &
          "  extNameDispatch(pIdx, nIdx) == edInplace and extInplaceActive(pIdx, nIdx, brokerCtx)\n"
      )
      src.add(
        "proc " & typeName & "ExtInplaceTry" & hookSfx & "(brokerCtx: BrokerContext" &
          hookParams & ", res: var " & resTy & "): bool {.gcsafe, raises: [].} =\n" &
          idxRead("brokerCtx") & "  if extNameDispatch(pIdx, nIdx) != edInplace or\n" &
          "      not extInplaceActive(pIdx, nIdx, brokerCtx):\n" & "    return false\n" &
          "  {.cast(gcsafe).}:\n" & "    let enc = " & encExpr & "\n" &
          "    if enc.isErr:\n" &
          "      res.err(\"EXTAPI: request encode failed: \" & enc.error)\n" &
          "      return true\n" &
          "    let r = extCallInplace(pIdx, nIdx, brokerCtx, enc.value)\n" &
          "    if r.isErr:\n" & "      res.err(r.error)\n" & "    else:\n" &
          "      res = extDecode_" & typeName & "(r.value)\n" & "  true\n"
      )
      # ExtTunnel adapter: raw CBOR in, typed `request`, raw CBOR out.
      let tunnelName = "extTunnel_" & typeName & "_" & tag
      var reqCall = "await " & typeName & ".request(ctx"
      var tunnelDecode = ""
      if params.len > 0:
        tunnelDecode =
          "  let d = cborDecode(payload, " & typeName & "ExtArgs" & tag & ")\n" &
          "  if d.isErr:\n" &
          "    return err(\"EXTAPI: tunnel request decode failed: \" & d.error)\n"
        for n in names:
          reqCall.add(", d.value." & n)
      reqCall.add(")")
      src.add(
        "proc " & tunnelName &
          "(ctx: BrokerContext, payload: seq[byte]): Future[Result[seq[byte], string]] {.async: (raises: []), gcsafe.} =\n" &
          tunnelDecode & "  let r = " & reqCall & "\n" & "  if r.isErr:\n" &
          "    return err(r.error)\n"
      )
      if isVoid:
        src.add("  return ok(newSeq[byte]())\n")
      else:
        src.add(
          "  let e = cborEncode(r.value)\n" & "  if e.isErr:\n" &
            "    return err(\"EXTAPI: tunnel reply encode failed: \" & e.error)\n" &
            "  return ok(e.value)\n"
        )
      let installName = "extInstall_" & typeName & "_" & tag
      let uninstallName = "extUninstall_" & typeName & "_" & tag
      src.add(
        "proc " & installName &
          "(ctx: BrokerContext, wirePublic: bool): Result[void, string] {.nimcall, gcsafe, raises: [].} =\n" &
          "  {.cast(gcsafe).}:\n" & "    discard " & laneType & ".setProvider(ctx, " &
          typeName & ".extLaneProvider(ctx))\n" & "    if wirePublic:\n" &
          "      return " & typeName & ".setProvider(ctx, " & typeName & ".extProvider" &
          sfx & "(ctx))\n" & "    return ok()\n"
      )
      src.add(
        "proc " & uninstallName &
          "(ctx: BrokerContext, siblingWired, publicWired, siblingProvided: bool) {.nimcall, gcsafe, raises: [].} =\n" &
          "  {.cast(gcsafe).}:\n" & "    if publicWired:\n" & "      if siblingWired:\n" &
          "        let withdrawn: " & providerType & " = proc(" & decl & "): Future[" &
          resTy & "] {.async.} =\n" &
          "          return err(\"EXTAPI: provider withdrawn\")\n" & "        discard " &
          typeName & ".replaceProvider(ctx, withdrawn)\n" & "      else:\n" & "        " &
          typeName & ".clearProvider(ctx)\n" & "    if not siblingProvided:\n" & "      " &
          laneType & ".clearProvider(ctx)\n"
      )
      gExtEntries.add(
        ExtEntryCT(
          plugin: plugin,
          wireName: wireName,
          kind: enkRequest,
          typeName: typeName,
          installName: installName,
          uninstallName: uninstallName,
          tunnelName: tunnelName,
          nameIdxVar: nameIdxVar,
          pluginIdxVar: pluginIdxVar,
          dispatch: dispatch.name,
          workers: dispatch.workers,
          autoWire: dispatch.autoWire,
          args: block:
            var a: seq[(string, string)]
            for p in params:
              let lastIdx = p.len - 1
              for nm in paramNames(@[p]):
                a.add((nm, p[lastIdx - 1].repr.strip()))
            a,
          payloadType: payloadSrc,
          payloadFields: payloadFieldPairs,
        )
      )

    if zeroPresent:
      emitSlot("zero", 0, wireBase & zeroSuffix, @[])
    if argPresent:
      emitSlot("arg", 1, wireBase & argSuffix, argParams)

    let gen = parseStmt(src)
    stampLineInfo(gen, modeNode)
    result.add(gen)
    when defined(brokerDebug):
      writeBrokerDebug(
        "RequestBrokerExt", typeName, result, header = "plugin='" & plugin & "'"
      )

proc generateExtEventBroker*(
    modeNode: NimNode, kwargs: seq[NimNode], body: NimNode
): NimNode {.raises: [ValueError].} =
  ## `EventBroker(EXTAPI[p])`: the plugin emits, Nim listens. The public
  ## broker is a plain MT EventBroker; the bridge decodes each foreign
  ## `emit` and re-emits it with the ordinary `T.emit(ctx, value)`.
  let plugin = pluginNameOf(modeNode)
  let (mtKw, extKw) = splitExtKwargs(kwargs)
  if extKw.len > 0:
    error("EventBroker(EXTAPI[...]) takes no EXTAPI kwargs", extKw[0])
  result = newStmtList()
  result.add(generateMtEventBroker(copyNimTree(body), parseMtEvtKwargs(mtKw)))
  when defined(BrokerFfiApi):
    let parsed = parseSingleTypeDef(body, "EventBroker", collectFieldInfo = true)
    let typeName = sanitizeIdentName(parsed.typeIdent)
    let emitName = "extEmit_" & typeName
    let valueSrc =
      if parsed.isVoid:
        "    " & typeName & ".emit(ctx, " & typeName & "())\n"
      else:
        "    let d = cborDecode(toOpenArray(cast[ptr UncheckedArray[byte]](buf), 0, len - 1), " &
          typeName & ")\n" & "    if d.isErr:\n" & "      return err(d.error)\n" & "    " &
          typeName & ".emit(ctx, d.value)\n"
    let tunnelName = "extTunnelListen_" & typeName
    let listenerSrc =
      if parsed.isVoid:
        "proc(): Future[void] {.async: (raises: []).} =\n" & "      cb(newSeq[byte]())\n"
      else:
        "proc(e: " & typeName & "): Future[void] {.async: (raises: []).} =\n" &
          "      let enc = cborEncode(e)\n" & "      if enc.isOk:\n" &
          "        cb(enc.value)\n"
    let tunnelSrc =
      "proc " & tunnelName &
      "(ctx: BrokerContext, cb: ExtTunnelEventCb): Result[void, string] {.nimcall, gcsafe, raises: [].} =\n" &
      "  {.cast(gcsafe).}:\n" & "    let r = " & typeName & ".listen(ctx, " & listenerSrc &
      "    )\n" & "    if r.isErr:\n" & "      return err(r.error)\n" &
      "    return ok()\n"
    let src =
      "var gExtNameIdx_" & typeName & "_event* {.global.}: int = -1\n" &
      "var gExtPluginIdx_" & typeName & "* {.global.}: int = -1\n" & "proc " & emitName &
      "(ctx: BrokerContext, buf: ptr uint8, len: int): Result[void, string] {.nimcall, gcsafe, raises: [].} =\n" &
      "  {.cast(gcsafe).}:\n" & valueSrc & "  ok()\n" & tunnelSrc
    let gen = parseStmt(src)
    stampLineInfo(gen, modeNode)
    result.add(gen)
    gExtEntries.add(
      ExtEntryCT(
        plugin: plugin,
        wireName: toSnakeCase(typeName),
        kind: enkEvent,
        typeName: typeName,
        emitName: emitName,
        tunnelName: tunnelName,
        nameIdxVar: "gExtNameIdx_" & typeName & "_event",
        pluginIdxVar: "gExtPluginIdx_" & typeName,
        payloadType: (if parsed.isVoid: "void" else: typeName),
        payloadFields: fieldPairs(parsed),
      )
    )

proc generateExtSignalBroker*(
    modeNode: NimNode, kwargs: seq[NimNode], body: NimNode
): NimNode {.raises: [ValueError].} =
  ## `SignalBroker(EXTAPI[p])`: Nim signals, the plugin handles (one-way).
  ## The public broker is a plain MT SignalBroker; when a plugin provides the
  ## name the bridge installs `T.extHandler(ctx)` as the signal handler.
  let plugin = pluginNameOf(modeNode)
  let (mtKw, extKw) = splitExtKwargs(kwargs)
  result = newStmtList()
  result.add(generateMtSignalBroker(copyNimTree(body), parseMtSigKwargs(mtKw)))
  when defined(BrokerFfiApi):
    let dispatch = extDispatchArg(extKw)
    let parsed = parseSingleTypeDef(body, "SignalBroker", collectFieldInfo = true)
    let typeName = sanitizeIdentName(parsed.typeIdent)
    let wireName = toSnakeCase(typeName)
    let nameIdxVar = "gExtNameIdx_" & typeName & "_signal"
    let pluginIdxVar = "gExtPluginIdx_" & typeName
    let handlerType = typeName & "SignalHandler"
    let (params, encSrc) =
      if parsed.isVoid:
        ("", "    let payload: seq[byte] = @[]\n")
      else:
        (
          "signalValue: " & typeName,
          "    let enc = cborEncode(signalValue)\n" & "    if enc.isErr:\n" &
            "      extWarnSignalDropped(\"" & wireName & "\", enc.error)\n" &
            "      return\n" & "    let payload = enc.value\n",
        )
    let installName = "extInstall_" & typeName & "_signal"
    let uninstallName = "extUninstall_" & typeName & "_signal"
    let callArgs = (if parsed.isVoid: "" else: "signalValue")
    let idxRead =
      "  var pIdx, nIdx: int\n" & "  {.cast(gcsafe).}:\n" & "    pIdx = " & pluginIdxVar &
      "\n" & "    nIdx = " & nameIdxVar & "\n"
    var src =
      "var " & pluginIdxVar & "* {.global.}: int = -1\n" & "var " & nameIdxVar &
      "* {.global.}: int = -1\n"
    # Handler: delivers to the external source, from any thread.
    src.add(
      "proc extHandler*(_: typedesc[" & typeName & "], ctx: BrokerContext): " &
        handlerType & " =\n" & idxRead & "  result = proc(" & params &
        "): Future[void] {.async: (raises: []), gcsafe.} =\n" & encSrc &
        "    let r = extSignal(pIdx, nIdx, ctx, payload)\n" & "    if r.isErr:\n" &
        "      extWarnSignalDropped(\"" & wireName & "\", r.error)\n"
    )
    src.add(
      "proc extFallback*(_: typedesc[" & typeName & "], ctx: BrokerContext, nimHandler: " &
        handlerType & "): " & handlerType & " =\n" & "  let fwd = " & typeName &
        ".extHandler(ctx)\n" & idxRead & "  result = proc(" & params &
        "): Future[void] {.async: (raises: []), gcsafe.} =\n" &
        "    if extAvailable(pIdx, nIdx, ctx):\n" & "      await fwd(" & callArgs & ")\n" &
        "    else:\n" & "      await nimHandler(" & callArgs & ")\n"
    )
    src.add(
      "proc extAvailable*(_: typedesc[" & typeName & "], ctx: BrokerContext): bool =\n" &
        idxRead & "  extAvailable(pIdx, nIdx, ctx)\n"
    )
    let tunnelName = "extTunnelSig_" & typeName
    src.add(
      "proc " & tunnelName &
        "(ctx: BrokerContext, payload: seq[byte]): Result[void, string] {.nimcall, gcsafe, raises: [].} =\n" &
        "  {.cast(gcsafe).}:\n"
    )
    if parsed.isVoid:
      src.add("    return " & typeName & ".signal(ctx)\n")
    else:
      src.add(
        "    let d = cborDecode(payload, " & typeName & ")\n" & "    if d.isErr:\n" &
          "      return err(\"EXTAPI: tunnel signal decode failed: \" & d.error)\n" &
          "    return " & typeName & ".signal(ctx, d.value)\n"
      )
    src.add(
      "proc " & installName &
        "(ctx: BrokerContext, wirePublic: bool): Result[void, string] {.nimcall, gcsafe, raises: [].} =\n" &
        "  {.cast(gcsafe).}:\n" & "    if wirePublic:\n" & "      return " & typeName &
        ".onSignal(ctx, " & typeName & ".extHandler(ctx))\n" & "    return ok()\n"
    )
    src.add(
      "proc " & uninstallName &
        "(ctx: BrokerContext, siblingWired, publicWired, siblingProvided: bool) {.nimcall, gcsafe, raises: [].} =\n" &
        "  {.cast(gcsafe).}:\n" & "    if publicWired:\n" & "      discard " & typeName &
        ".dropSignalHandler(ctx)\n"
    )
    let gen = parseStmt(src)
    stampLineInfo(gen, modeNode)
    result.add(gen)
    gExtEntries.add(
      ExtEntryCT(
        plugin: plugin,
        wireName: wireName,
        kind: enkSignal,
        typeName: typeName,
        installName: installName,
        uninstallName: uninstallName,
        tunnelName: tunnelName,
        nameIdxVar: nameIdxVar,
        pluginIdxVar: pluginIdxVar,
        dispatch: dispatch.name,
        workers: dispatch.workers,
        autoWire: dispatch.autoWire,
        payloadType: (if parsed.isVoid: "void" else: typeName),
        payloadFields: fieldPairs(parsed),
      )
    )

{.pop.}
