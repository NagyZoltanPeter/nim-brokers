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
  ./ext_types,
  ./broker_debug

# The EXTAPI runtime (process globals, std/dynlib, std/json, the CBOR codec)
# is only needed when EXTAPI brokers are bound to foreign code; without the
# FFI flag they are plain `(mt)` brokers and plain MT builds stay lean.
when defined(BrokerFfiApi):
  import ./api_cbor_codec, ./ext_runtime
  export api_cbor_codec, ext_runtime

export mt_request_broker, mt_config, ext_types

type ExtEntryCT* = object
  plugin*: string
  wireName*: string
  kind*: ExtNameKind
  typeName*: string ## dispatch tag type; dual-slot siblings share it
  installName*: string
  uninstallName*: string
  emitName*: string
  tunnelName*: string ## ExtTunnel adapter proc for this name
  dynlibSrc*: string ## K1: Nim expression of the `dynlib` pattern ("" = not an import)
  importResolveName*: string ## K1: resolver proc
  importTrampName*: string ## K1: CBOR trampoline proc
  rawPtrArgs*: bool ## K1 short form with ptr / pointer / openArray / cstring args
  peerLib*: string ## K2: peer nim-brokers library name ("" = not a peer import)
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
): tuple[
  name: string,
  workers: int,
  autoWire: string,
  importc: string,
  dynlibSrc: string,
  importLib: string,
] {.compileTime.} =
  for kw in ext:
    if kw[0].eqIdent("dispatch"):
      let d = parseDispatch(kw[1])
      result.name = d.name
      result.workers = d.workers
    elif kw[0].eqIdent("autoWire"):
      result.autoWire = parseBoolLit(kw[1], "autoWire")
    elif kw[0].eqIdent("importc"):
      if kw[1].kind notin {nnkStrLit, nnkTripleStrLit, nnkRStrLit}:
        error("EXTAPI `importc` expects the C symbol as a string literal", kw[1])
      result.importc = kw[1].strVal
    elif kw[0].eqIdent("dynlib"):
      # A string literal or any Nim expression (e.g. a const) evaluated at load.
      result.dynlibSrc = kw[1].repr
    elif kw[0].eqIdent("importLib"):
      if kw[1].kind notin {nnkStrLit, nnkTripleStrLit, nnkRStrLit}:
        error(
          "EXTAPI `importLib` expects the peer library name as a string literal", kw[1]
        )
      result.importLib = kw[1].strVal
  if result.importLib.len > 0 and result.dynlibSrc.len == 0:
    macros.error("EXTAPI `importLib` needs `dynlib = <peer library pattern>`")
  if result.importLib.len > 0 and result.importc.len > 0:
    macros.error(
      "EXTAPI: `importLib` (peer library) and `importc` (C function) exclude each other"
    )

proc isImportcProc(n: NimNode): bool {.compileTime.} =
  if n.kind != nnkProcDef or n[4].kind != nnkPragma:
    return false
  for pr in n[4]:
    if (pr.kind == nnkIdent and pr.eqIdent("importc")) or
        (pr.kind in {nnkExprColonExpr, nnkCall} and pr[0].eqIdent("importc")):
      return true
  false

proc importcSymbol(n: NimNode): string {.compileTime.} =
  let nm = (if n[0].kind == nnkPostfix: $n[0][1] else: $n[0])
  for pr in n[4]:
    if pr.kind in {nnkExprColonExpr, nnkCall} and pr[0].eqIdent("importc") and pr.len > 1 and
        pr[1].kind in {nnkStrLit, nnkTripleStrLit, nnkRStrLit}:
      return pr[1].strVal
  nm

proc isRawPtrType(t: string): bool {.compileTime.} =
  let l = t.strip().toLowerAscii()
  l.startsWith("ptr ") or l == "pointer" or l.startsWith("openarray") or l == "cstring"

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
  for kw in extKw:
    if kw[0].eqIdent("dispatch") and kw[1].kind == nnkIdent and kw[1].eqIdent("inplace"):
      for mk in mtKw:
        if mk[0].eqIdent("requestTimeoutMs"):
          warning(
            "EXTAPI `dispatch = inplace` runs synchronously on the caller's thread: " &
              "`requestTimeoutMs` / `setRequestTimeout` and `cancel` do not apply to it " &
              "(`requestCancellable` returns id 0)",
            mk,
          )
  # 1. The public broker: a plain MT RequestBroker. Under the FFI flag it gets
  #    the inplace hook: the effective dispatch is only known once
  #    registerExtPlugin applies the plugin default, so the hook checks it at
  #    runtime (an array read; the source table is consulted only for
  #    `inplace` names).
  # Parsed afresh rather than copied: a `let` copy of an object in the
  # compile-time VM can alias the original, and the lane must not get the hook.
  let laneCfg = parseMtReqKwargs(mtKw)
  # K1 imports: `{.importc.}` prototypes and signature bodies (adapters) are
  # ours, not the MT broker's — strip them before handing the body on.
  var protos: seq[NimNode]
  var zeroBody, argBody: NimNode = nil
  var stripped = body
  if body.kind == nnkStmtList:
    stripped = newStmtList()
    for stmt in body:
      if isImportcProc(stmt):
        protos.add(stmt)
        continue
      if stmt.kind == nnkProcDef and stmt[6].kind != nnkEmpty:
        let c = copyNimTree(stmt)
        c[6] = newEmptyNode()
        if stmt.params.len - 1 == 0:
          zeroBody = stmt[6]
        else:
          argBody = stmt[6]
        stripped.add(c)
        continue
      stripped.add(copyNimTree(stmt))
  when defined(BrokerFfiApi):
    cfg.extInplaceHook = true
  result.add(generateMtRequestBroker(copyNimTree(stripped), cfg))
  when not defined(BrokerFfiApi):
    # Without the FFI flag EXTAPI degrades to `(mt)`: callable, mockable,
    # just not bindable from foreign code (§4).
    discard extKw
    return
  else:
    let dispatch = extDispatchArg(extKw)
    let body = stripped
    let isPeer = dispatch.importLib.len > 0
    let isImport =
      (dispatch.dynlibSrc.len > 0 and not isPeer) or dispatch.importc.len > 0 or
      protos.len > 0 or not zeroBody.isNil or not argBody.isNil
    if isPeer and (protos.len > 0 or not zeroBody.isNil or not argBody.isNil):
      error("EXTAPI peer import (`importLib`) takes signatures only", modeNode)
    if isImport and dispatch.dynlibSrc.len == 0:
      error("EXTAPI native import needs `dynlib = \"<library pattern>\"`", modeNode)

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
    # The lane never times out on its own: the bridge's `extCall` enforces the
    # public broker's deadline. Set once here (module init), never per call.
    src.add(laneType & ".setRequestTimeout(InfiniteDuration)\n")
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
        laneType & "ProviderWithArgs =\n" &
        "  result = proc(slot: int32, req: seq[byte]): Future[Result[" & laneType &
        ", string]] {.async.} =\n" & "    var pIdx, nZero, nArg: int\n" &
        "    {.cast(gcsafe).}:\n" & "      pIdx = " & pluginIdxVar & "\n" &
        "      nZero = " & zeroIdxVar & "\n" & "      nArg = " & argIdxVar & "\n" &
        "    let tmo = " & typeName & ".requestTimeout()\n" &
        "    let r = await extCall(pIdx, (if slot == 0: nZero else: nArg), ctx, req, tmo)\n" &
        "    if r.isErr:\n" & "      return err(r.error)\n" & "    return ok(" & laneType &
        "(payload: r.value))\n"
    )

    # K1: C function pointers + resolver (broker level).
    var resolveLines = ""
    proc fnVar(suffix: string, params: seq[NimNode], ret: string, sym: string): string =
      let v = "gExtImpFn_" & typeName & "_" & suffix
      let pt =
        "proc(" & paramDeclSrc(params) & ")" & (if ret.len > 0: ": " & ret
        else: "") & " {.cdecl, gcsafe, raises: [].}"
      src.add("var " & v & "* {.global.}: " & pt & "\n")
      resolveLines.add(
        "    block:\n" & "      let a = symAddr(lib, \"" & sym & "\")\n" &
          "      if a.isNil:\n" & "        missing.add(\"" & sym & "\")\n" &
          "      else:\n" & "        " & v & " = cast[" & pt & "](a)\n"
      )
      v

    var protoWrappers = ""
    if isImport:
      if isSugar:
        error("EXTAPI native imports need the `proc signature*` form", modeNode)
      for pr in protos:
        let pname = (if pr[0].kind == nnkPostfix: $pr[0][1]
        else: $pr[0])
        var pparams: seq[NimNode]
        for i in 1 ..< pr.params.len:
          pparams.add(pr.params[i])
        let ret = (if pr.params[0].kind == nnkEmpty: ""
        else: pr.params[0].repr.strip())
        let v = fnVar(pname, pparams, ret, importcSymbol(pr))
        protoWrappers.add(
          "      proc " & pname & "(" & paramDeclSrc(pparams) & ")" &
            (if ret.len > 0: ": " & ret else: "") & " =\n" & "        " & v & "(" &
            paramNames(pparams).join(", ") & ")\n"
        )
      if dispatch.importc.len > 0 and zeroPresent and argPresent:
        error("EXTAPI `importc` short form needs a single signature", modeNode)

    var bodySplices: seq[(string, NimNode)]

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
      # Raw C pointers (K1 short form, `inplace` only) cannot be marshalled:
      # every CBOR path of such a slot is an explicit error; only the native
      # in-place call serves it.
      var slotRawPtr = false
      if isImport:
        for p in params:
          if isRawPtrType(p[p.len - 2].repr):
            slotRawPtr = true
      const rawPtrErr =
        "\"EXTAPI: raw-pointer arguments cannot be marshalled (inplace native call only)\""
      if params.len == 0:
        encExpr = "Result[seq[byte], string].ok(newSeq[byte]())"
      elif slotRawPtr:
        encExpr = "Result[seq[byte], string].err(" & rawPtrErr & ")"
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
      proc idxRead(ctxName: string, ind = "  "): string =
        ## Read the plugin / name index globals. Closures call it inside their
        ## body, so a closure built before `registerExtPlugin`'s initialiser
        ## ran still finds the plugin (EXTAPI review M9).
        ind & "var pIdx, nIdx: int\n" & ind & "{.cast(gcsafe).}:\n" & ind & "  pIdx = " &
          pluginIdxVar & "\n" & ind & "  nIdx = " & nameIdxVar & "\n"

      # K1: typed sync adapter (the native call) + CBOR trampoline.
      let adapterName = "extImport_" & typeName & "_" & tag
      let trampName = "extImportTramp_" & typeName & "_" & tag
      if isImport:
        let ubody = (if tag == "zero": zeroBody else: argBody)
        if ubody.isNil:
          if dispatch.importc.len == 0:
            error(
              "EXTAPI native import: give `importc = \"<symbol>\"` or a signature body",
              modeNode,
            )
          var ret = ""
          if not isVoid:
            if payloadFieldPairs.len != 1:
              error(
                "EXTAPI `importc` short form needs a response object with exactly one field (the C return value)",
                modeNode,
              )
            ret = payloadFieldPairs[0][1]
          # The short form hands Nim values straight to a `cdecl` C prototype,
          # so every argument / the return value must have a C ABI layout:
          # scalars, enums, distinct-of-scalar, `ptr` / `pointer` / `cstring`,
          # POD objects. Managed types (string, seq, ref, objects holding
          # them) differ between --mm:refc and --mm:orc and are never C.
          var abiTypes: seq[string]
          for p in params:
            let pt = p[p.len - 2].repr.strip()
            let lpt = pt.toLowerAscii()
            if lpt.startsWith("openarray") or lpt.startsWith("varargs"):
              error(
                "EXTAPI `importc` short form: `" & pt &
                  "` has no C ABI (pass `ptr T` + a length, or use the body form)",
                modeNode,
              )
            abiTypes.add(pt)
          if ret.len > 0:
            abiTypes.add(ret)
          for t in abiTypes:
            src.add(
              "when not supportsCopyMem(" & t & "):\n" &
                "  {.error: \"EXTAPI `importc` short form (" & typeName & "): `" & t &
                "` is not a C ABI type (managed: string / seq / ref / objects holding them); " &
                "use the body form and convert explicitly\".}\n"
            )
          let v = fnVar(tag, params, ret, dispatch.importc)
          src.add(
            "proc " & adapterName & "*(" & decl & "): " & resTy &
              " {.gcsafe, raises: [].} =\n" & "  {.cast(gcsafe).}:\n" & "    if " & v &
              ".isNil:\n" & "      return err(\"EXTAPI: import not loaded\")\n"
          )
          if isVoid:
            src.add("    " & v & "(" & callArgs & ")\n" & "    return ok()\n")
          else:
            src.add(
              "    return ok(" & payloadSrc & "(" & payloadFieldPairs[0][0] & ": " & v &
                "(" & callArgs & ")))\n"
            )
        else:
          src.add(
            "proc " & adapterName & "*(" & decl & "): " & resTy &
              " {.gcsafe, raises: [].} =\n" & "  {.cast(gcsafe).}:\n" & protoWrappers &
              "      try:\n" & "        discard \"EXT_BODY_" & tag & "\"\n" &
              "      except CatchableError as e:\n" &
              "        return err(\"EXTAPI: import adapter raised: \" & e.msg)\n"
          )
          bodySplices.add(("EXT_BODY_" & tag, ubody))
        # Trampoline: runs where the dispatch policy says (bridge / worker /
        # inplace caller), CBOR in and out.
        src.add(
          "proc " & trampName &
            "*(user: pointer, id: uint64, buf: ptr uint8, len: int) {.gcsafe, raises: [].} =\n" &
            "  {.cast(gcsafe).}:\n"
        )
        if slotRawPtr:
          src.add(
            "    discard buf\n    discard len\n    extImportReplyErr(user, id, " &
              rawPtrErr & ")\n    return\n"
          )
        elif params.len > 0:
          src.add(
            "    let d = cborDecode(toOpenArray(cast[ptr UncheckedArray[byte]](buf), 0, len - 1), " &
              typeName & "ExtArgs" & tag & ")\n" & "    if d.isErr:\n" &
              "      extImportReplyErr(user, id, \"EXTAPI: import args decode failed: \" & d.error)\n" &
              "      return\n"
          )
          var dargs: seq[string]
          for n in names:
            dargs.add("d.value." & n)
          src.add("    let r = " & adapterName & "(" & dargs.join(", ") & ")\n")
        else:
          src.add("    let r = " & adapterName & "()\n")
        if not slotRawPtr:
          src.add(
            "    if r.isErr:\n" & "      extImportReplyErr(user, id, r.error)\n" &
              "      return\n"
          )
        if slotRawPtr:
          discard
        elif isVoid:
          src.add("    extImportReplyOk(user, id, newSeq[byte]())\n")
        else:
          src.add(
            "    let e = cborEncode(r.value)\n" & "    if e.isErr:\n" &
              "      extImportReplyErr(user, id, \"EXTAPI: import reply encode failed: \" & e.error)\n" &
              "      return\n" & "    extImportReplyOk(user, id, e.value)\n"
          )

      # Forwarder: serves one call from the external source, from any thread.
      src.add(
        "proc extProvider" & sfx & "*(_: typedesc[" & typeName &
          "], ctx: BrokerContext): " & providerType & " =\n" & "  result = proc(" & decl &
          "): Future[" & resTy & "] {.async.} =\n" & idxRead("ctx", "    ") & (
          # A native import served inplace is a direct C call: before any CBOR
          # encoding, which raw-pointer arguments cannot go through.
          if isImport:
            "    if extNameDispatch(pIdx, nIdx) == edInplace and\n" &
              "        extNativeProvided(pIdx, nIdx, ctx):\n" & "      return " &
              adapterName & "(" & callArgs & ")\n"
          else:
            ""
        ) & "    let enc = " & encExpr & "\n" & "    if enc.isErr:\n" &
          "      return err(\"EXTAPI: request encode failed: \" & enc.error)\n" &
          "    var r: Result[seq[byte], string]\n" &
          "    if extNameDispatch(pIdx, nIdx) == edInplace:\n" &
          "      r = extCallInplace(pIdx, nIdx, ctx, enc.value)\n" &
          "    elif extOnBridge():\n" & "      let tmo = " & typeName &
          ".requestTimeout()\n" &
          "      r = await extCall(pIdx, nIdx, ctx, enc.value, tmo)\n" & "    else:\n" &
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
          "  result = proc(" & decl & "): Future[" & resTy & "] {.async.} =\n" &
          idxRead("ctx", "    ") & "    if extAvailable(pIdx, nIdx, ctx):\n" &
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
          idxRead("brokerCtx") & "  if extNameDispatch(pIdx, nIdx) != edInplace:\n" &
          "    return false\n" &
          "  let route = extInplaceRoute(pIdx, nIdx, brokerCtx) # one table lookup\n" &
          "  if route == 0:\n" & "    return false\n" & (
          if isImport:
            "  if route == 2:\n" & "    {.cast(gcsafe).}:\n" & "      res = " &
              adapterName & "(" & callArgs & ")\n" & "    return true\n"
          else:
            ""
        ) & "  {.cast(gcsafe).}:\n" & "    let enc = " & encExpr & "\n" &
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
      if slotRawPtr:
        tunnelDecode = "  discard payload\n  return err(" & rawPtrErr & ")\n"
      elif params.len > 0:
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
          tunnelDecode
      )
      if not slotRawPtr:
        src.add(
          "  let r = " & reqCall & "\n" & "  if r.isErr:\n" & "    return err(r.error)\n"
        )
      if slotRawPtr:
        discard
      elif isVoid:
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
          "  {.cast(gcsafe).}:\n" & "    discard " & laneType & ".replaceProvider(ctx, " &
          typeName & ".extLaneProvider(ctx))\n" & "    if wirePublic:\n" &
          # replace-or-insert on the bridge: also replaces the bridge's own
          # "withdrawn" stub left by a dual-slot uninstall, and still refuses
          # a slot owned by another thread (setupBucket fails there).
          "      return " & typeName & ".replaceProvider(ctx, " & typeName &
          ".extProvider" & sfx & "(ctx))\n" & "    return ok()\n"
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
          dynlibSrc: (if isImport or isPeer: dispatch.dynlibSrc else: ""),
          importResolveName: (if isImport: "extResolve_" & typeName else: ""),
          importTrampName: (if isImport: trampName else: ""),
          rawPtrArgs: slotRawPtr, # short and body form alike (review M11)
          peerLib: dispatch.importLib,
        )
      )

    if zeroPresent:
      emitSlot("zero", 0, wireBase & zeroSuffix, @[])
    if argPresent:
      emitSlot("arg", 1, wireBase & argSuffix, argParams)
    if isImport:
      src.add(
        "proc extResolve_" & typeName &
          "*(lib: LibHandle): string {.nimcall, gcsafe, raises: [].} =\n" &
          "  var missing: seq[string]\n" & "  {.cast(gcsafe).}:\n" & resolveLines &
          "  extJoinMissing(missing)\n"
      )

    let gen = parseStmt(src)
    # Splice the user's adapter bodies over their placeholders.
    proc splice(n: NimNode) =
      for i in 0 ..< n.len:
        let c = n[i]
        if c.kind == nnkDiscardStmt and c.len == 1 and c[0].kind == nnkStrLit:
          for (marker, b) in bodySplices:
            if c[0].strVal == marker:
              n[i] = copyNimTree(b)
        else:
          splice(c)

    # Stamp first so the user's adapter body keeps its own line info.
    stampLineInfo(gen, modeNode)
    splice(gen)
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
  for kw in extKw:
    if not (kw[0].eqIdent("importLib") or kw[0].eqIdent("dynlib")):
      error("EventBroker(EXTAPI[...]) only takes `importLib` / `dynlib`", kw)
  result = newStmtList()
  result.add(generateMtEventBroker(copyNimTree(body), parseMtEvtKwargs(mtKw)))
  when defined(BrokerFfiApi):
    let evKw = extDispatchArg(extKw)
    if evKw.dynlibSrc.len > 0 and evKw.importLib.len == 0:
      error(
        "EventBroker(EXTAPI[...]): `dynlib` alone is a native C import, which serves " &
          "requests only — an event can only be imported from a nim-brokers peer " &
          "(`importLib = \"<lib>\", dynlib = ...`)",
        modeNode,
      )
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
    # Tunnel listeners: the handle stays on the listening thread (a threadvar)
    # and the caller gets its id as a token for `ExtTunnel.unlisten`.
    let tvName = "gExtTunnelListeners_" & typeName
    let unlistenName = "extTunnelUnlisten_" & typeName
    let tunnelSrc =
      "var " & tvName & " {.threadvar.}: seq[" & typeName & "Listener]\n" & "proc " &
      tunnelName &
      "(ctx: BrokerContext, cb: ExtTunnelEventCb): Result[uint64, string] {.nimcall, gcsafe, raises: [].} =\n" &
      "  {.cast(gcsafe).}:\n" & "    let r = " & typeName & ".listen(ctx, " & listenerSrc &
      "    )\n" & "    if r.isErr:\n" & "      return err(r.error)\n" & "    " & tvName &
      ".add(r.value)\n" & "    return ok(r.value.id)\n" & "proc " & unlistenName &
      "(ctx: BrokerContext, token: uint64): Future[void] {.nimcall, async: (raises: []), gcsafe.} =\n" &
      "  var found = false\n" & "  var h: " & typeName & "Listener\n" &
      "  {.cast(gcsafe).}:\n" & "    for i in 0 ..< " & tvName & ".len:\n" & "      if " &
      tvName & "[i].id == token:\n" & "        h = " & tvName & "[i]\n" & "        " &
      tvName & ".del(i)\n" & "        found = true\n" & "        break\n" &
      "  if found:\n" & "    await " & typeName & ".dropListener(ctx, h)\n"
    let src =
      "var gExtNameIdx_" & typeName & "_event* {.global.}: int = -1\n" &
      "var gExtPluginIdx_" & typeName & "* {.global.}: int = -1\n" & "proc " & emitName &
      "(ctx: BrokerContext, buf: ptr uint8, len: int): Result[void, string] {.nimcall, gcsafe, raises: [].} =\n" &
      "  {.cast(gcsafe).}:\n" & valueSrc & "  ok()\n" & tunnelSrc
    let gen = parseStmt(src)
    stampLineInfo(gen, modeNode)
    result.add(gen)
    when defined(brokerDebug):
      writeBrokerDebug(
        "EventBrokerExt", typeName, result, header = "plugin='" & plugin & "'"
      )
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
        peerLib: evKw.importLib,
        dynlibSrc: evKw.dynlibSrc,
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
    if dispatch.dynlibSrc.len > 0 and dispatch.importLib.len == 0:
      error(
        "SignalBroker(EXTAPI[...]): `dynlib` alone is a native C import, which serves " &
          "requests only — a signal can only be imported from a nim-brokers peer " &
          "(`importLib = \"<lib>\", dynlib = ...`)",
        modeNode,
      )
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
    proc sigIdxRead(ind: string): string =
      ind & "var pIdx, nIdx: int\n" & ind & "{.cast(gcsafe).}:\n" & ind & "  pIdx = " &
        pluginIdxVar & "\n" & ind & "  nIdx = " & nameIdxVar & "\n"

    let idxRead = sigIdxRead("  ")
    var src =
      "var " & pluginIdxVar & "* {.global.}: int = -1\n" & "var " & nameIdxVar &
      "* {.global.}: int = -1\n"
    # Handler: delivers to the external source, from any thread.
    src.add(
      "proc extHandler*(_: typedesc[" & typeName & "], ctx: BrokerContext): " &
        handlerType & " =\n" & "  result = proc(" & params &
        "): Future[void] {.async: (raises: []), gcsafe.} =\n" & sigIdxRead("    ") &
        encSrc & "    let r = extSignal(pIdx, nIdx, ctx, payload)\n" &
        "    if r.isErr:\n" & "      extWarnSignalDropped(\"" & wireName &
        "\", r.error)\n"
    )
    src.add(
      "proc extFallback*(_: typedesc[" & typeName & "], ctx: BrokerContext, nimHandler: " &
        handlerType & "): " & handlerType & " =\n" & "  let fwd = " & typeName &
        ".extHandler(ctx)\n" & "  result = proc(" & params &
        "): Future[void] {.async: (raises: []), gcsafe.} =\n" & sigIdxRead("    ") &
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
    when defined(brokerDebug):
      writeBrokerDebug(
        "SignalBrokerExt", typeName, result, header = "plugin='" & plugin & "'"
      )
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
        peerLib: dispatch.importLib,
        dynlibSrc: dispatch.dynlibSrc,
      )
    )

{.pop.}
