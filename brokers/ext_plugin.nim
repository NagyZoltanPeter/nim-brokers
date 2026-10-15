## EXTAPI — consuming external (plugin) APIs through brokers.
##
## Declare brokers with `RequestBroker(EXTAPI[<plugin>], …)`, then call
## `registerExtPlugin(<plugin>)` once in the compilation root. Foreign plugins
## wire themselves through the `broker_ext_host` function table
## (`brokers/broker_ext.h`); Nim code keeps using the ordinary broker verbs.
## See doc/design/EXTAPI_PLAN.md.

{.push raises: [].}

import std/[macros, algorithm, strutils, os]
import ./internal/ext_brokers
import ./internal/ext_runtime
import ./internal/ext_shapes
import ./broker_context
import chronos
import ./internal/ext_codegen_hpp
import ./internal/ext_codegen_rust
import ./internal/ext_codegen_go
import ./internal/ext_codegen_py
import
  ./internal/api_schema_hash, ./internal/api_outdir, ./internal/api_codegen_cbor_cddl

export ext_brokers, ext_runtime

type ExtHost* = object ## Namespace for the process-wide EXTAPI host (exe mode).

proc start*(_: typedesc[ExtHost]): Result[void, string] =
  ## Start the shared bridge thread. Required before any plugin can open a
  ## port. Idempotent.
  extHostStart()

proc stop*(_: typedesc[ExtHost]): Result[void, string] =
  ## Close every port, fail pending calls (calls queued for a worker never
  ## run), clear auto-wired providers, stop the worker pools, K2 peer contexts
  ## and the bridge thread. `err` on the bridge or a worker thread — it would
  ## have to join itself. Idempotent; safe against concurrent `start`.
  extHostStop()

proc table*(_: typedesc[ExtHost]): ptr ExtHostTable =
  ## The `broker_ext_host` function table to hand to a plugin entry point.
  extHostTable()

type ExtPlugin* = object ## Namespace for native-import plugins (K1).

proc load*(
    _: typedesc[ExtPlugin], name: string, ctx: BrokerContext = DefaultBrokerContext
): Result[void, string] =
  ## Resolve the plugin's C symbols (`std/dynlib`, lazily, never aborting the
  ## program) and serve every resolved name on `ctx`. Missing libraries or
  ## symbols leave their names unprovided — see `loadError`.
  extImportLoad(extPluginIndex(name), ctx)

proc loadError*(_: typedesc[ExtPlugin], name: string): string =
  ## Diagnostics of the last `load` ("" when everything resolved).
  extImportLoadError(extPluginIndex(name))

type ExtTunnel* = object
  ## Nim-side raw CBOR access to EXTAPI brokers by (plugin, wire name), for
  ## generic forwarders. Every call goes through the typed broker, so it
  ## reaches whatever provider is installed — plugin, fallback or Nim impl —
  ## with the broker's timeout and "no provider" semantics (EXTAPI_PLAN §6.6.4).

proc call*(
    _: typedesc[ExtTunnel], ctx: BrokerContext, plugin, name: string, payload: seq[byte]
): Future[Result[seq[byte], string]] {.async: (raises: []).} =
  ## Request: `payload` is the CBOR argument map (empty for zero-arg); the
  ## result is the bare CBOR reply value.
  let (p, n) = extFindName(plugin, name)
  if p < 0 or n < 0:
    return err("unknown ext api " & plugin & "." & name)
  let fn = extNameDesc(p, n).tunnelCall
  if fn.isNil:
    return err("ext api " & plugin & "." & name & " is not a request")
  return await fn(ctx, payload)

proc signal*(
    _: typedesc[ExtTunnel], ctx: BrokerContext, plugin, name: string, payload: seq[byte]
): Result[void, string] =
  let (p, n) = extFindName(plugin, name)
  if p < 0 or n < 0:
    return err("unknown ext api " & plugin & "." & name)
  let fn = extNameDesc(p, n).tunnelSignal
  if fn.isNil:
    return err("ext api " & plugin & "." & name & " is not a signal")
  fn(ctx, payload)

proc listen*(
    _: typedesc[ExtTunnel],
    ctx: BrokerContext,
    plugin, name: string,
    cb: ExtTunnelEventCb,
): Result[uint64, string] =
  ## Every event of (plugin, name) on `ctx` is re-encoded and handed to `cb`
  ## on the listening thread. Returns a token for `unlisten` (same thread).
  let (p, n) = extFindName(plugin, name)
  if p < 0 or n < 0:
    return err("unknown ext api " & plugin & "." & name)
  let fn = extNameDesc(p, n).tunnelListen
  if fn.isNil:
    return err("ext api " & plugin & "." & name & " is not an event")
  fn(ctx, cb)

proc unlisten*(
    _: typedesc[ExtTunnel], ctx: BrokerContext, plugin, name: string, token: uint64
): Future[void] {.async: (raises: []).} =
  ## Remove a listener added by `listen` on this thread; unknown tokens are a
  ## no-op.
  let (p, n) = extFindName(plugin, name)
  if p < 0 or n < 0:
    return
  let fn = extNameDesc(p, n).tunnelUnlisten
  if not fn.isNil:
    await fn(ctx, token)

proc loadPlugin*(_: typedesc[ExtHost], path: string): Result[void, string] =
  ## Exe mode: `dlopen` / `LoadLibrary` a plugin shared library and call its
  ## `broker_ext_plugin_entry(host)`. The library stays loaded for the life of
  ## the process (unloading under running foreign code is never safe).
  extLoadPlugin(path)

{.pop.}

proc cborHead(major, v: int): string {.compileTime.} =
  let m = major shl 5
  if v < 24:
    result.add(char(m or v))
  elif v < 256:
    result.add(char(m or 24))
    result.add(char(v))
  elif v < 65536:
    result.add(char(m or 25))
    result.add(char(v shr 8))
    result.add(char(v and 0xFF))
  else:
    result.add(char(m or 26))
    for sh in [24, 16, 8, 0]:
      result.add(char((v shr sh) and 0xFF))

proc cborText(s: string): string {.compileTime.} =
  cborHead(3, s.len) & s

proc cborArr(items: seq[string]): string {.compileTime.} =
  result = cborHead(4, items.len)
  for i in items:
    result.add(i)

proc cborMap(pairs: seq[(string, string)]): string {.compileTime.} =
  result = cborHead(5, pairs.len)
  for (k, v) in pairs:
    result.add(cborText(k))
    result.add(v)

proc nimStrLit(s: string): string {.compileTime.} =
  result = "\""
  for c in s:
    result.add("\\x" & toHex(ord(c), 2))
  result.add("\"")

proc fieldsCbor(fields: seq[(string, string)]): string {.compileTime.} =
  var items: seq[string]
  for (n, t) in fields:
    items.add(cborMap(@[("name", cborText(n)), ("type", cborText(t))]))
  cborArr(items)

proc stampLineInfoExt(n, src: NimNode) {.compileTime.} =
  n.copyLineInfo(src)
  for c in n:
    stampLineInfoExt(c, src)

var gExtPluginNamesCT {.compileTime.}: seq[string]

proc sortedExtEntries(plugin: string): seq[ExtEntryCT] {.compileTime.} =
  for e in gExtEntries:
    if e.plugin == plugin:
      result.add(e)
  result.sort(
    proc(a, b: ExtEntryCT): int =
      cmp(a.wireName, b.wireName)
  )

proc emitExtPlugin(args: NimNode, shapes: seq[string]): NimNode {.compileTime.} =
  ## The body of `registerExtPlugin`, run once the wire shapes of every
  ## argument / payload type are known (`shapes`, in `sortedExtEntries` order:
  ## per entry its argument types, then its payload type unless void).
  if args.len == 0 or args[0].kind != nnkIdent:
    error("registerExtPlugin expects the plugin identifier first", args)
  let plugin = $args[0]
  var version = "0.1.0"
  var defDispatch = ("bridge", 0)
  var defAutoWire = "true"
  var loadEager = false
  for i in 1 ..< args.len:
    let kw = args[i]
    if kw.kind != nnkExprEqExpr:
      error("registerExtPlugin expects `name = value` kwargs", kw)
    if kw[0].eqIdent("version"):
      version = kw[1].strVal
    elif kw[0].eqIdent("dispatch"):
      defDispatch = parseDispatch(kw[1])
    elif kw[0].eqIdent("autoWire"):
      defAutoWire = parseBoolLit(kw[1], "autoWire")
    elif kw[0].eqIdent("load"):
      if kw[1].kind != nnkIdent or $kw[1] notin ["eager", "manual"]:
        error("registerExtPlugin: `load` must be `eager` or `manual`", kw[1])
      loadEager = $kw[1] == "eager"
    else:
      error("registerExtPlugin: unknown kwarg `" & $kw[0] & "`", kw)
  result = newStmtList()
  when not defined(BrokerFfiApi):
    return
  else:
    var entries = sortedExtEntries(plugin)
    if entries.len == 0:
      error(
        "registerExtPlugin(" & plugin & "): no EXTAPI[" & plugin & "] broker declared",
        args[0],
      )
    for i in 1 ..< entries.len:
      if entries[i].wireName == entries[i - 1].wireName:
        error(
          "registerExtPlugin(" & plugin & "): duplicate wire name '" &
            entries[i].wireName & "'",
          args[0],
        )
    let n = entries.len
    # Limits of the runtime registry, known here at compile time (review M10):
    # failing at runtime would only report "plugin not registered" per call.
    if n > ExtMaxNames:
      error(
        "registerExtPlugin(" & plugin & "): " & $n & " names, at most " & $ExtMaxNames &
          " per plugin (the provided-set bitmask width) — split it into two plugins",
        args[0],
      )
    if plugin notin gExtPluginNamesCT:
      gExtPluginNamesCT.add(plugin)
      if gExtPluginNamesCT.len > ExtMaxPlugins:
        error(
          "registerExtPlugin(" & plugin & "): more than " & $ExtMaxPlugins &
            " EXTAPI plugins in one program",
          args[0],
        )

    # Wire shapes (ext_shapes): structural, nested types included (review M13).
    var argShapes: seq[seq[(string, string)]] # per entry: (arg name, shape)
    var payloadShapes: seq[string]
    var si = 0
    for e in entries:
      var a: seq[(string, string)]
      for (an, _) in e.args:
        a.add((an, (if si < shapes.len: shapes[si] else: "?")))
        inc si
      a.sort(
        proc(x, y: (string, string)): int =
          cmp(x[0], y[0])
      )
      argShapes.add(a)
      if e.payloadType == "void":
        payloadShapes.add("void")
      else:
        payloadShapes.add((if si < shapes.len: shapes[si] else: "?"))
        inc si

    # Schema fingerprint: names, kinds and the wire shape of every argument and
    # payload (nested objects, enum ordinals, containers — not type names).
    var canon: seq[string]
    for i, e in entries:
      var args: seq[string]
      for (an, sh) in argShapes[i]:
        args.add(an & ":" & sh)
      canon.add(
        $e.kind & ":" & e.wireName & "(" & args.join(",") & ")->" & payloadShapes[i]
      )
    canon.sort()
    let schemaHash =
      fnv1a128Hex("brokers-ext:2\nplugin:" & plugin & "\n" & canon.join("\n"))

    # Discovery blobs (CBOR, built at compile time, static storage).
    var reqNames, evtNames, sigNames, reqRecs, evtRecs, sigRecs: seq[string]
    for e in entries:
      case e.kind
      of enkRequest:
        reqNames.add(cborText(e.wireName))
        reqRecs.add(
          cborMap(
            @[
              ("name", cborText(e.wireName)),
              ("args", fieldsCbor(e.args)),
              ("response", cborText(e.payloadType)),
              ("fields", fieldsCbor(e.payloadFields)),
            ]
          )
        )
      of enkEvent:
        evtNames.add(cborText(e.wireName))
        evtRecs.add(
          cborMap(
            @[
              ("name", cborText(e.wireName)),
              ("type", cborText(e.payloadType)),
              ("fields", fieldsCbor(e.payloadFields)),
            ]
          )
        )
      of enkSignal:
        sigNames.add(cborText(e.wireName))
        sigRecs.add(
          cborMap(
            @[
              ("name", cborText(e.wireName)),
              ("type", cborText(e.payloadType)),
              ("fields", fieldsCbor(e.payloadFields)),
            ]
          )
        )
    let head = @[
      ("plugin", cborText(plugin)),
      ("version", cborText(version)),
      ("schemaHash", cborText(schemaHash)),
    ]
    let listBlob = cborMap(
      head &
        @[
          ("requests", cborArr(reqNames)),
          ("events", cborArr(evtNames)),
          ("signals", cborArr(sigNames)),
        ]
    )
    let schemaBlob = cborMap(
      head &
        @[
          ("requests", cborArr(reqRecs)),
          ("events", cborArr(evtRecs)),
          ("signals", cborArr(sigRecs)),
        ]
    )

    # <plugin>_ext.h (names + hash, no codec), broker_ext.h copy, <plugin>_ext.cddl.
    let outDir = detectOutputDir()
    if outDir.len > 0:
      ensureGeneratedOutputDir(outDir)
      let up = plugin.toUpperAscii()
      var h =
        "/* " & plugin &
        "_ext.h — generated by nim-brokers registerExtPlugin. Do not edit. */\n" &
        "#ifndef " & up & "_EXT_H\n#define " & up &
        "_EXT_H\n\n#include \"broker_ext.h\"\n\n" & "#define " & up & "_EXT_PLUGIN \"" &
        plugin & "\"\n" & "#define " & up & "_EXT_VERSION \"" & version & "\"\n" &
        "#define " & up & "_EXT_SCHEMA_HASH \"" & schemaHash & "\"\n\n"
      for e in entries:
        h.add(
          "#define " & up & "_EXT_" & e.wireName.toUpperAscii() & " \"" & e.wireName &
            "\"\n"
        )
      h.add("\nenum " & plugin & "_ext_name_idx {\n")
      for i, e in entries:
        h.add("  " & up & "_EXT_IDX_" & e.wireName.toUpperAscii() & " = " & $i & ",\n")
      h.add("  " & up & "_EXT_NAME_COUNT = " & $n & "\n};\n\n#endif\n")
      var cddl =
        "; " & plugin & " EXTAPI plugin — generated by nim-brokers. Do not edit.\n" &
        "; schemaHash " & schemaHash &
        "\n; reply: bare value on REPLY_OK, UTF-8 text on REPLY_ERR\n\n"
      var typeRules: seq[string]
      proc cddlType(t: string): string =
        let lt = t.replace(" ", "").toLowerAscii()
        if lt in ["seq[byte]", "seq[uint8]"]:
          "bstr"
        else:
          nimTypeToCddl(t)

      proc mapRule(fs: seq[(string, string)]): string =
        var parts: seq[string]
        for (fname, ft) in fs:
          parts.add(fname & ": " & cddlType(ft))
        "{ " & parts.join(", ") & " }"

      for e in entries:
        case e.kind
        of enkRequest:
          if e.args.len == 0:
            cddl.add("; " & e.wireName & ": no arguments, empty payload\n")
          else:
            cddl.add(e.wireName & "-args = " & mapRule(e.args) & "\n")
          cddl.add(e.wireName & "-reply = " & e.payloadType & "\n")
        of enkEvent:
          cddl.add(e.wireName & "-event = " & e.payloadType & "\n")
        of enkSignal:
          cddl.add(e.wireName & "-signal = " & e.payloadType & "\n")
        if e.payloadFields.len > 0:
          let rule = e.payloadType & " = " & mapRule(e.payloadFields) & "\n"
          if rule notin typeRules:
            typeRules.add(rule)
      cddl.add("\n" & typeRules.join(""))
      try:
        writeFile(outDir / (plugin & "_ext.h"), h)
        writeFile(outDir / (plugin & "_ext.cddl"), cddl)
        # Only plugins implemented by foreign code get a C++ wrapper; native
        # (K1) and peer (K2) imports are served by generated Nim adapters.
        var foreignImpl = true
        for e in entries:
          if e.dynlibSrc.len > 0:
            foreignImpl = false
        if foreignImpl:
          writeFile(
            outDir / (plugin & "_ext.hpp"),
            generateExtCppHeader(plugin, version, schemaHash, entries),
          )
          when defined(BrokerFfiApiGenRust):
            let crate = generateExtRustCrate(plugin, version, schemaHash, entries)
            ensureGeneratedOutputDir(outDir / (plugin & "_ext_rs"))
            ensureGeneratedOutputDir(outDir / (plugin & "_ext_rs") / "src")
            writeFile(outDir / (plugin & "_ext_rs") / "Cargo.toml", crate.cargo)
            writeFile(outDir / (plugin & "_ext_rs") / "src" / "lib.rs", crate.lib)
          when defined(BrokerFfiApiGenPy):
            writeFile(
              outDir / (plugin & "_ext.py"),
              generateExtPyFile(plugin, version, schemaHash, entries, defDispatch[0]),
            )
          when defined(BrokerFfiApiGenGo):
            let gm = generateExtGoModule(plugin, version, schemaHash, entries)
            let goDir = outDir / (plugin & "_ext_go")
            ensureGeneratedOutputDir(goDir)
            writeFile(goDir / "go.mod", gm.gomod)
            writeFile(goDir / (plugin & "_ext.go"), gm.main)
            writeFile(goDir / (plugin & "_ext_export.go"), gm.exports)
            writeFile(
              goDir / "broker_ext.h",
              staticRead(currentSourcePath().parentDir / "broker_ext.h"),
            )
        writeFile(
          outDir / "broker_ext.h",
          staticRead(currentSourcePath().parentDir / "broker_ext.h"),
        )
      except IOError as e:
        error("registerExtPlugin: cannot write generated files: " & e.msg, args[0])

    let namesVar = "gExtNames_" & plugin
    let descVar = "gExtDesc_" & plugin
    # K2 peer imports: every name comes from the same peer library.
    var peers = 0
    for e in entries:
      if e.peerLib.len > 0:
        inc peers
    let isPeerPlugin = peers > 0
    if isPeerPlugin:
      if peers != entries.len:
        error(
          "registerExtPlugin(" & plugin &
            "): a peer-import plugin imports every name with `importLib`",
          args[0],
        )
      for e in entries:
        if e.peerLib != entries[0].peerLib or e.dynlibSrc != entries[0].dynlibSrc:
          error(
            "registerExtPlugin(" & plugin &
              "): all names must import the same peer library",
            args[0],
          )
    # K1 native imports: the plugin is either all imports or all foreign.
    var imports = 0
    for e in entries:
      if e.dynlibSrc.len > 0 and e.peerLib.len == 0:
        inc imports
    let isImportPlugin = imports > 0
    if isImportPlugin and imports != entries.len:
      error(
        "registerExtPlugin(" & plugin &
          "): a plugin is either all native imports (`dynlib`) or all foreign brokers",
        args[0],
      )
    if not isImportPlugin and not isPeerPlugin and loadEager:
      error("registerExtPlugin: `load` applies to native-import plugins only", args[0])
    var src =
      "var " & namesVar & " {.global.}: array[" & $n & ", ExtNameDesc]\n" & "var " &
      descVar & " {.global.}: ExtPluginDesc\n"
    if isImportPlugin:
      src.add(
        "proc extImportInvoke_" & plugin &
          "(user: pointer, id: uint64, nameIdx: uint32, name: cstring, buf: ptr uint8, len: csize_t) {.cdecl, gcsafe, raises: [].} =\n" &
          "  case int(nameIdx)\n"
      )
      for i, e in entries:
        src.add("  of " & $i & ": " & e.importTrampName & "(user, id, buf, int(len))\n")
      src.add("  else: discard\n")
    src.add("proc extInitPlugin_" & plugin & "() =\n")
    var poolSize = 0
    for e in entries:
      if e.dispatch == "workers":
        poolSize = max(poolSize, e.workers)
      elif e.dispatch == "" and defDispatch[0] == "workers" and e.kind != enkEvent:
        poolSize = max(poolSize, defDispatch[1])
    for i, e in entries:
      var sibling = -1
      for j, o in entries:
        if j != i and o.kind == enkRequest and e.kind == enkRequest and
            o.typeName == e.typeName:
          sibling = j
      let eff = (if e.dispatch.len > 0: e.dispatch else: defDispatch[0])
      if e.rawPtrArgs and eff != "inplace":
        error(
          "registerExtPlugin(" & plugin & "): '" & e.wireName &
            "' passes raw pointers (ptr / pointer / openArray / cstring) to C; that is " &
            "only safe with `dispatch = inplace` — for `" & eff & "`, take values " &
            "(e.g. `seq[byte]`) in the signature and pass pointers to C inside a body",
          args[0],
        )
      let disp =
        case eff
        of "workers": "edWorkers"
        of "inplace": "edInplace"
        else: "edBridge"
      let kind = (
        case e.kind
        of enkRequest: "enkRequest"
        of enkSignal: "enkSignal"
        of enkEvent: "enkEvent"
      )
      src.add(
        "  " & namesVar & "[" & $i & "] = ExtNameDesc(name: \"" & e.wireName &
          "\", kind: " & kind & ", dispatch: " & disp & ", install: " &
          (if e.installName.len > 0: e.installName else: "nil") & ", uninstall: " &
          (if e.uninstallName.len > 0: e.uninstallName else: "nil") & ", emitFn: " &
          (if e.emitName.len > 0: e.emitName else: "nil") & ", sibling: " & $sibling &
          ", autoWire: " & (if e.autoWire.len > 0: e.autoWire else: defAutoWire) & (
          if e.tunnelName.len == 0: ""
          elif e.kind == enkRequest: ", tunnelCall: " & e.tunnelName
          elif e.kind == enkSignal: ", tunnelSignal: " & e.tunnelName
          else:
            ", tunnelListen: " & e.tunnelName & ", tunnelUnlisten: extTunnelUnlisten_" &
              e.typeName
        ) & (
          if e.dynlibSrc.len > 0 and e.peerLib.len == 0:
            ", importLib: cstring(" & e.dynlibSrc & "), importResolve: " &
              e.importResolveName
          else:
            ""
        ) & (
          if e.peerLib.len > 0:
            block:
              var a: seq[string]
              for (an, sh) in argShapes[i]:
                a.add(an & ":" & sh)
              ", peerSig: " & nimStrLit(a.join(",") & "|" & payloadShapes[i])
          else:
            ""
        ) & ")\n"
      )
    src.add(
      "  " & descVar & " = ExtPluginDesc(name: \"" & plugin & "\", version: \"" & version &
        "\", schemaHash: \"" & schemaHash & "\", skipSchemaEnv: \"" &
        plugin.toUpperAscii().replace("-", "_") & "_SKIP_SCHEMA_CHECK" &
        "\", listApisBuf: cstring(" & nimStrLit(listBlob) & "), listApisLen: " &
        $listBlob.len & ", schemaBuf: cstring(" & nimStrLit(schemaBlob) &
        "), schemaLen: " & $schemaBlob.len &
        ", names: cast[ptr UncheckedArray[ExtNameDesc]](addr " & namesVar &
        "[0]), nameCount: " & $n & ", workers: " & $poolSize & (
        if isImportPlugin:
          ", importInvoke: extImportInvoke_" & plugin & ", loadEager: " & $loadEager
        elif isPeerPlugin:
          ", peerLib: \"" & entries[0].peerLib & "\", peerDynlib: cstring(" &
            entries[0].dynlibSrc & "), loadEager: " & $loadEager
        else:
          ""
      ) & ")\n" & "  let pIdx = extRegisterPlugin(addr " & descVar & ")\n"
    )
    var seenPluginVars: seq[string]
    for i, e in entries:
      if e.pluginIdxVar notin seenPluginVars:
        seenPluginVars.add(e.pluginIdxVar)
        src.add("  " & e.pluginIdxVar & " = pIdx\n")
      src.add("  " & e.nameIdxVar & " = " & $i & "\n")
    src.add("extInitPlugin_" & plugin & "()\n")
    result.add(parseStmt(src))
    stampLineInfoExt(result, args[0])

var gExtPendingArgs {.compileTime.}: seq[(string, NimNode)]

macro extRegisterPluginShaped*(plugin: static string, shapes: static string): untyped =
  ## Second stage of `registerExtPlugin`: `shapes` was computed by the typed
  ## `extTypeShapes` from the plugin's argument / payload types.
  var args: NimNode = nil
  for (p, a) in gExtPendingArgs:
    if p == plugin:
      args = a
  if args.isNil:
    error("registerExtPlugin(" & plugin & "): internal: arguments not recorded")
  emitExtPlugin(args, (if shapes.len == 0: @[]
    else: shapes.split(ShapeSep)))

macro registerExtPlugin*(args: varargs[untyped]): untyped =
  ## `registerExtPlugin(storage, version = "1.0.0")`
  ##
  ## Two stages: this untyped stage hands every argument / payload type of the
  ## plugin's brokers to the typed `extTypeShapes`, whose wire shapes (nested
  ## objects, enum ordinals) the second stage puts into the schema hash and
  ## the K2 peer signatures.
  if args.len == 0 or args[0].kind != nnkIdent:
    error("registerExtPlugin expects the plugin identifier first", args)
  when not defined(BrokerFfiApi):
    return emitExtPlugin(args, @[]) # validates the kwargs, emits nothing
  else:
    let plugin = $args[0]
    var shapesCall = newCall(bindSym("extTypeShapes"))
    for e in sortedExtEntries(plugin):
      for (_, at) in e.args:
        shapesCall.add(parseExpr(at))
      if e.payloadType != "void":
        shapesCall.add(parseExpr(e.payloadType))
    gExtPendingArgs.add((plugin, copyNimTree(args)))
    result = newCall(bindSym("extRegisterPluginShaped"), newLit(plugin), shapesCall)

macro exportExtHost*(libName: static string): untyped =
  ## Lib mode: export `<libName>_extHost()` from a Nim shared library. The C /
  ## C++ / Rust host app calls it (after `<libName>_initialize()`) to get the
  ## `broker_ext_host` table and provide plugins in-process. The first call
  ## starts the EXTAPI bridge thread.
  let fname = libName & "_extHost"
  let src =
    "proc " & fname & "*(): ptr ExtHostTable {.exportc: \"" & fname &
    "\", cdecl, dynlib.} =\n" & "  when compileOption(\"app\", \"lib\"):\n" &
    "    when declared(setupForeignThreadGc):\n" &
    # Once per foreign thread. Under refc the registration is never torn down
    # (Nim has no hook for a foreign thread's exit); call `<lib>_extHost()`
    # from long-lived threads.
    "      var registered {.threadvar.}: bool\n" & "      if not registered:\n" &
    "        registered = true\n" & "        setupForeignThreadGc()\n" &
    "  if ExtHost.start().isErr:\n" & "    return nil\n" & "  ExtHost.table()\n"
  result = parseStmt(src)
