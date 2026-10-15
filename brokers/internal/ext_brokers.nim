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
  nameIdxVar*: string
  pluginIdxVar*: string
  dispatch*: string ## "" = the plugin default
  workers*: int ## n of `workers(n)`, 0 otherwise
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

proc extDispatchArg(
    ext: seq[NimNode]
): tuple[name: string, workers: int] {.compileTime.} =
  for kw in ext:
    if kw[0].eqIdent("dispatch"):
      return parseDispatch(kw[1])
    elif kw[0].eqIdent("importc") or kw[0].eqIdent("dynlib") or
        kw[0].eqIdent("importLib") or kw[0].eqIdent("autoWire"):
      error("EXTAPI kwarg `" & $kw[0] & "` is not implemented yet", kw)
  ("", 0)

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
  let cfg = parseMtReqKwargs(mtKw)
  result = newStmtList()
  # 1. The public broker: a plain MT RequestBroker.
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

    var src = "var " & pluginIdxVar & "* {.global.}: int = -1\n"

    proc decodeSrc(): string =
      if isVoid:
        "    return ok()\n"
      else:
        "    let d = cborDecode(r.value, " & payloadSrc & ")\n" & "    if d.isErr:\n" &
          "      return err(\"EXTAPI: reply decode failed: \" & d.error)\n" &
          "    return ok(d.value)\n"

    proc emitSlot(tag: string, wireName: string, params: seq[NimNode]) =
      let nameIdxVar = "gExtNameIdx_" & typeName & "_" & tag
      let providerType =
        typeName & (if params.len == 0: "ProviderNoArgs" else: "ProviderWithArgs")
      let fwdName = if params.len == 0 and dual: "extProviderNoArgs" else: "extProvider"
      let decl = paramDeclSrc(params)
      let names = paramNames(params)
      var encSrc: string
      if params.len == 0:
        encSrc = "    let payload: seq[byte] = @[]\n"
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
        encSrc =
          "    let enc = cborEncode(" & ctor & ")\n" & "    if enc.isErr:\n" &
          "      return err(\"EXTAPI: request encode failed: \" & enc.error)\n" &
          "    let payload = enc.value\n"
      src.add("var " & nameIdxVar & "* {.global.}: int = -1\n")
      src.add(
        "proc " & fwdName & "*(_: typedesc[" & typeName & "], ctx: BrokerContext): " &
          providerType & " =\n" & "  var pIdx, nIdx: int\n" & "  {.cast(gcsafe).}:\n" &
          "    pIdx = " & pluginIdxVar & "\n" & "    nIdx = " & nameIdxVar & "\n" &
          "  result = proc(" & decl & "): Future[Result[" & payloadSrc &
          ", string]] {.async.} =\n" & encSrc & "    var tmo: Duration\n" &
          "    {.cast(gcsafe).}:\n" & "      tmo = g" & typeName & "MtTimeout\n" &
          "    let r = await extCall(pIdx, nIdx, ctx, payload, tmo)\n" &
          "    if r.isErr:\n" & "      return err(r.error)\n" & decodeSrc()
      )
      let installName = "extInstall_" & typeName & "_" & tag
      let uninstallName = "extUninstall_" & typeName & "_" & tag
      src.add(
        "proc " & installName &
          "(ctx: BrokerContext): Result[void, string] {.nimcall, gcsafe, raises: [].} =\n" &
          "  {.cast(gcsafe).}:\n" & "    return " & typeName & ".setProvider(ctx, " &
          typeName & "." & fwdName & "(ctx))\n"
      )
      src.add(
        "proc " & uninstallName &
          "(ctx: BrokerContext, siblingWired: bool) {.nimcall, gcsafe, raises: [].} =\n" &
          "  {.cast(gcsafe).}:\n" & "    if siblingWired:\n" & "      let withdrawn: " &
          providerType & " = proc(" & decl & "): Future[Result[" & payloadSrc &
          ", string]] {.async.} =\n" &
          "        return err(\"EXTAPI: provider withdrawn\")\n" & "      discard " &
          typeName & ".replaceProvider(ctx, withdrawn)\n" & "    else:\n" & "      " &
          typeName & ".clearProvider(ctx)\n"
      )
      gExtEntries.add(
        ExtEntryCT(
          plugin: plugin,
          wireName: wireName,
          kind: enkRequest,
          typeName: typeName,
          installName: installName,
          uninstallName: uninstallName,
          nameIdxVar: nameIdxVar,
          pluginIdxVar: pluginIdxVar,
          dispatch: dispatch.name,
          workers: dispatch.workers,
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
      emitSlot("zero", wireBase & zeroSuffix, @[])
    if argPresent:
      emitSlot("arg", wireBase & argSuffix, argParams)

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
    let src =
      "var gExtNameIdx_" & typeName & "_event* {.global.}: int = -1\n" &
      "var gExtPluginIdx_" & typeName & "* {.global.}: int = -1\n" & "proc " & emitName &
      "(ctx: BrokerContext, buf: ptr uint8, len: int): Result[void, string] {.nimcall, gcsafe, raises: [].} =\n" &
      "  {.cast(gcsafe).}:\n" & valueSrc & "  ok()\n"
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
    let src =
      "var " & pluginIdxVar & "* {.global.}: int = -1\n" & "var " & nameIdxVar &
      "* {.global.}: int = -1\n" & "proc extHandler*(_: typedesc[" & typeName &
      "], ctx: BrokerContext): " & handlerType & " =\n" & "  var pIdx, nIdx: int\n" &
      "  {.cast(gcsafe).}:\n" & "    pIdx = " & pluginIdxVar & "\n" & "    nIdx = " &
      nameIdxVar & "\n" & "  result = proc(" & params &
      "): Future[void] {.async: (raises: []), gcsafe.} =\n" & encSrc &
      "    let r = extSignal(pIdx, nIdx, ctx, payload)\n" & "    if r.isErr:\n" &
      "      extWarnSignalDropped(\"" & wireName & "\", r.error)\n" & "proc " &
      installName &
      "(ctx: BrokerContext): Result[void, string] {.nimcall, gcsafe, raises: [].} =\n" &
      "  {.cast(gcsafe).}:\n" & "    return " & typeName & ".onSignal(ctx, " & typeName &
      ".extHandler(ctx))\n" & "proc " & uninstallName &
      "(ctx: BrokerContext, siblingWired: bool) {.nimcall, gcsafe, raises: [].} =\n" &
      "  {.cast(gcsafe).}:\n" & "    discard " & typeName & ".dropSignalHandler(ctx)\n"
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
        nameIdxVar: nameIdxVar,
        pluginIdxVar: pluginIdxVar,
        dispatch: dispatch.name,
        workers: dispatch.workers,
        payloadType: (if parsed.isVoid: "void" else: typeName),
        payloadFields: fieldPairs(parsed),
      )
    )

{.pop.}
