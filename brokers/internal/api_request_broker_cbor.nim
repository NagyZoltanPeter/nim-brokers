## API RequestBroker — CBOR mode codegen
## --------------------------------------
## Generates the CBOR-mode surface for `RequestBroker(API)` declarations.
##
## For each declaration this module emits:
##
## 1. The underlying multi-thread RequestBroker, exactly as the native path
##    does — providers register and run on the processing thread the same
##    way regardless of FFI mode. Internal cross-thread dispatch stays as
##    typed `Channel[T]` traffic; CBOR encoding only happens at the C ABI
##    boundary.
##
## 2. (When the signature has arguments) a synthetic per-request CBOR args
##    object that mirrors the parameter list field-by-field. Decoding the
##    foreign request buffer into this object gives us individual local
##    variables to forward into the broker's `request` call.
##
## 3. A CBOR adapter proc with the canonical signature
##
##      proc <Type>CborAdapter*(ctx: BrokerContext, reqBuf: seq[byte]):
##          Future[seq[byte]] {.async: (raises: []).}
##
##    The adapter decodes the request buffer (or ignores it for zero-arg
##    requests), `await`s the typed broker call, and encodes the resulting
##    `Result[T, string]` as a CBOR response envelope.
##
## 4. A compile-time entry in `gApiCborRequestEntries` so the upcoming
##    `registerBrokerLibrary` CBOR backend can wire the adapter into the
##    library's dispatch table.
##
## The wire `apiName` is the snake_case form of the response type name —
## e.g. `InitializeRequest` becomes `initialize_request`. Foreign wrappers
## are generated to use the same name so the C entry point sees a stable
## identifier per broker.

{.push raises: [].}

import std/[macros, strutils]
import
  ./helper/broker_utils,
  ./mt_request_broker,
  ./mt_config,
  ./api_common,
  ./api_cbor_codec,
  ./api_schema,
  ./api_type_resolver

# `api_type_resolver` re-export: `autoRegisterApiType` is emitted into the
# user-library AST by the broker macros and must resolve at the user's
# expansion site. Previously this came in transitively via the native
# `api_request_broker` re-export chain (retired in Part A); re-export it
# explicitly here so user code never needs a direct
# `import brokers/internal/api_type_resolver`.
export mt_request_broker, mt_config, api_common, api_cbor_codec, api_type_resolver

# ---------------------------------------------------------------------------
# Schema registration
# ---------------------------------------------------------------------------

proc registerCborObjectType*(
    typeName: string, fieldNames, fieldTypes: seq[NimNode]
) {.compileTime.} =
  ## Register a parsed object type in `gApiTypeRegistry` so the C++ /
  ## Python / etc. wrapper codegen can emit typed structs for it.
  ## Idempotent — subsequent calls for the same type are a no-op so a
  ## type that ends up registered through both the auto-resolver and a
  ## broker macro doesn't double-list.
  if isTypeRegistered(typeName):
    return
  var entry = ApiTypeEntry(name: typeName, kind: atkObject)
  for i in 0 ..< fieldNames.len:
    var fname = $fieldNames[i]
    # `fieldNames` from parseSingleTypeDef carry the original AST,
    # which for inline `object` types is a plain Ident (export marker
    # already lifted by the parser). Strip a trailing '*' defensively.
    if fname.endsWith("*"):
      fname.setLen(fname.len - 1)
    let ftype = fieldTypes[i].repr.strip()
    entry.fields.add(ApiFieldDef(name: fname, nimType: ftype))
  registerTypeEntry(entry)

proc registerCborPrimitiveType*(
    typeName: string, parsed: ParsedBrokerType
) {.compileTime.} =
  ## Register a primitive (non-object) broker type — `type X = int32` — as a
  ## distinct alias of its underlying primitive. Wrapper codegen then emits a
  ## `using X = <prim>` alias and treats X as an emittable scalar payload (the
  ## CBOR wire value is a bare scalar, not a map). A no-op for non-primitive
  ## non-object types, which stay TODO-stubbed in the wrappers.
  if isTypeRegistered(typeName):
    return
  if parsed.objectDef.kind == nnkDistinctTy and parsed.objectDef.len == 1 and
      parsed.objectDef[0].kind == nnkIdent and isNimPrimitive($parsed.objectDef[0]) and
      ($parsed.objectDef[0]).toLowerAscii() notin ["string", "cstring"]:
    registerTypeEntry(makeAliasEntry(typeName, $parsed.objectDef[0], atkDistinct))

# ---------------------------------------------------------------------------
# Adapter proc type — exposed so registerBrokerLibrary (CBOR mode) can
# materialise a uniform table of dispatchers.
# ---------------------------------------------------------------------------

type CborApiAdapter* = proc(ctx: BrokerContext, reqBuf: seq[byte]): Future[seq[byte]] {.
  async: (raises: []), gcsafe
.}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc collectSignatures(
    body: NimNode
): tuple[
  zeroArg: NimNode,
  argSig: NimNode,
  argParams: seq[NimNode],
  zeroArgName: string,
  argSigName: string,
] {.compileTime.} =
  ## Walk the macro body and split the (at most two) `signature*` proc
  ## declarations into the zero-arg and arg-based slots, mirroring
  ## `mt_request_broker` and the native path's handling.
  result.zeroArg = nil
  result.argSig = nil
  result.argParams = @[]
  result.zeroArgName = ""
  result.argSigName = ""

  for stmt in body:
    if stmt.kind != nnkProcDef:
      continue
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
    let paramCount = params.len - 1
    if paramCount == 0:
      result.zeroArg = stmt
      result.zeroArgName = $procNameIdent
    elif paramCount >= 1:
      result.argSig = stmt
      result.argSigName = $procNameIdent
      for idx in 1 ..< params.len:
        result.argParams.add(copyNimTree(params[idx]))

proc snakeApiName(typeIdent: NimNode): string {.compileTime.} =
  ## Wire `apiName` for a request: snake_case form of the response type
  ## identifier. e.g. `InitializeRequest` -> `initialize_request`.
  toSnakeCase(sanitizeIdentName(typeIdent))

proc emitArgsType(
    argsTypeIdent: NimNode, argParams: seq[NimNode]
): NimNode {.compileTime.} =
  ## Build `type <argsTypeIdent>* = object\n  field1*: T1\n  field2*: T2`
  ## from the arg-based signature's parameter nodes.
  ##
  ## Each `argParams[i]` is an `nnkIdentDefs` node carrying one or more
  ## names plus a type. We expand each name into its own field so an arg
  ## like `(a, b: int32)` produces two separate object fields.
  var recList = newNimNode(nnkRecList)
  for paramDefs in argParams:
    let lastIdx = paramDefs.len - 1
    let typeNode = paramDefs[lastIdx - 1]
    for nameIdx in 0 ..< lastIdx - 1:
      let nameNode = paramDefs[nameIdx]
      let fieldIdent =
        case nameNode.kind
        of nnkIdent, nnkSym:
          ident($nameNode)
        of nnkPostfix:
          ident($nameNode[1])
        of nnkPragmaExpr:
          ident($nameNode[0])
        else:
          ident($nameNode)
      recList.add(
        newTree(
          nnkIdentDefs, postfix(fieldIdent, "*"), copyNimTree(typeNode), newEmptyNode()
        )
      )

  newTree(
    nnkTypeSection,
    newTree(
      nnkTypeDef,
      postfix(argsTypeIdent, "*"),
      newEmptyNode(),
      newTree(nnkObjectTy, newEmptyNode(), newEmptyNode(), recList),
    ),
  )

# ---------------------------------------------------------------------------
# Adapter emission
# ---------------------------------------------------------------------------

proc emitZeroArgAdapter(
    typeIdent: NimNode, adapterIdent: NimNode
): NimNode {.compileTime.} =
  ## Adapter for a zero-argument request: ignore the input buffer, await
  ## the broker call, encode the response envelope.
  quote:
    proc `adapterIdent`*(
        ctx: BrokerContext, reqBuf: seq[byte]
    ): Future[seq[byte]] {.async: (raises: []), gcsafe.} =
      discard reqBuf
      let r = await `typeIdent`.request(ctx)
      let envBytes = cborEncodeResultEnvelope(r)
      if envBytes.isOk:
        return envBytes.value
      let errEnv = cborEncodeResultEnvelope(
        Result[`typeIdent`, string].err("response encode failed: " & envBytes.error)
      )
      if errEnv.isOk:
        return errEnv.value
      return @[]

proc emitArgAdapter(
    typeIdent: NimNode,
    adapterIdent: NimNode,
    argsTypeIdent: NimNode,
    argParams: seq[NimNode],
): NimNode {.compileTime, raises: [ValueError].} =
  ## Adapter for an arg-based request. Decodes the request buffer into the
  ## synthesised `argsTypeIdent`, awaits the broker call with each field
  ## unpacked positionally, and encodes the resulting envelope.
  ##
  ## The proc body is rendered as a Nim source string and parsed back via
  ## `parseStmt`. This sidesteps the awkward interaction between `quote
  ## do:`'s gensym'd proc parameters and pre-built call nodes — every
  ## identifier in the rendered string lives in the same local scope, so
  ## name resolution is straightforward.
  var fieldNames: seq[string] = @[]
  for paramDefs in argParams:
    let lastIdx = paramDefs.len - 1
    for nameIdx in 0 ..< lastIdx - 1:
      let nameNode = paramDefs[nameIdx]
      let nameStr =
        case nameNode.kind
        of nnkIdent, nnkSym:
          $nameNode
        of nnkPostfix:
          $nameNode[1]
        of nnkPragmaExpr:
          $nameNode[0]
        else:
          $nameNode
      fieldNames.add(nameStr)

  var argList = ""
  for f in fieldNames:
    argList.add(", decoded." & f)

  let typeIdentName = $typeIdent
  let argsTypeIdentName = $argsTypeIdent
  let adapterIdentName = $adapterIdent

  let src =
    "proc " & adapterIdentName & "*(\n" & "    ctx: BrokerContext, reqBuf: seq[byte]\n" &
    "): Future[seq[byte]] {.async: (raises: []), gcsafe.} =\n" &
    "  let decRes = cborDecode(reqBuf, " & argsTypeIdentName & ")\n" &
    "  if decRes.isErr:\n" & "    let errEnv = cborEncodeResultEnvelope(\n" &
    "      Result[" & typeIdentName &
    ", string].err(\"request decode failed: \" & decRes.error)\n" & "    )\n" &
    "    if errEnv.isOk:\n" & "      return errEnv.value\n" & "    return @[]\n" &
    "  let decoded = decRes.value\n" & "  let r = await " & typeIdentName &
    ".request(ctx" & argList & ")\n" & "  let envBytes = cborEncodeResultEnvelope(r)\n" &
    "  if envBytes.isOk:\n" & "    return envBytes.value\n" &
    "  let errEnv = cborEncodeResultEnvelope(\n" & "    Result[" & typeIdentName &
    ", string].err(\"response encode failed: \" & envBytes.error)\n" & "  )\n" &
    "  if errEnv.isOk:\n" & "    return errEnv.value\n" & "  return @[]\n"

  parseStmt(src)

# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

proc generateApiCborRequestBrokerImpl(
    body: NimNode, cfg: MtReqCfg
): NimNode {.raises: [ValueError].} =
  ## Deferred-phase codegen for `RequestBroker(API)` under CBOR mode.
  ## Runs after the typed-phase `autoRegisterApiType` calls have populated
  ## `gApiTypeRegistry` for any external types referenced in the broker
  ## response object or signature parameters (enums, distinct types,
  ## nested objects). Wrapper codegen consumes that registry to emit
  ## typed dataclasses / encoders / decoders.
  result = newStmtList()

  # 1. Emit the underlying MT broker (typed Nim<->Nim dispatch on the
  #    processing thread, identical to the native path). Capacity
  #    config flows in from the outer RequestBroker(API, ...) kwargs —
  #    same knobs as RequestBroker(mt).
  result.add(generateMtRequestBroker(copyNimTree(body), cfg))

  # 2. Parse the response type identifier and register its fields in the
  #    schema so wrapper codegen can emit typed structs for it.
  let parsed = parseSingleTypeDef(
    body, "RequestBroker", allowRefToNonObject = true, collectFieldInfo = true
  )
  let typeIdent = parsed.typeIdent
  let typeName = sanitizeIdentName(typeIdent)
  let apiName = snakeApiName(typeIdent)
  if parsed.hasInlineFields:
    registerCborObjectType(typeName, parsed.fieldNames, parsed.fieldTypes)
  elif parsed.isVoid:
    # `void` → a zero-field object: payload-less request, the response
    # envelope carries only the ok/err signal.
    registerCborObjectType(typeName, @[], @[])
  else:
    registerCborPrimitiveType(typeName, parsed)

  # 3. Collect zero-arg and arg-based signatures.
  let sigs = collectSignatures(body)

  # Materialise (paramName, nimType) pairs from the arg-based signature so
  # foreign-language wrapper codegen can emit a typed call signature.
  proc paramFields(argParams: seq[NimNode]): seq[(string, string)] {.compileTime.} =
    for paramDefs in argParams:
      let lastIdx = paramDefs.len - 1
      let typeNode = paramDefs[lastIdx - 1]
      let typeStr = typeNode.repr.strip()
      for nameIdx in 0 ..< lastIdx - 1:
        let nameNode = paramDefs[nameIdx]
        let nameStr =
          case nameNode.kind
          of nnkIdent, nnkSym:
            $nameNode
          of nnkPostfix:
            $nameNode[1]
          of nnkPragmaExpr:
            $nameNode[0]
          else:
            $nameNode
        result.add((nameStr, typeStr))

  if sigs.zeroArg.isNil and sigs.argSig.isNil:
    # No explicit signature — treat as zero-arg, matching the native
    # macro's defaulting.
    let adapterIdent = ident(typeName & "CborAdapter")
    result.add(emitZeroArgAdapter(typeIdent, adapterIdent))
    registerCborRequestEntry(apiName, $adapterIdent, typeName, @[])
    return

  proc sigNameSuffix(sigName: string): string =
    if sigName.len <= "signature".len:
      return ""
    toSnakeCase(sigName["signature".len .. ^1])

  # Zero-arg adapter (suffixed when both signatures coexist on this broker).
  if not sigs.zeroArg.isNil:
    let zeroAdapterTag = if not sigs.argSig.isNil: "Zero" else: ""
    let zeroApiSuffix =
      if not sigs.argSig.isNil:
        let s = sigNameSuffix(sigs.zeroArgName)
        if s.len > 0:
          "_" & s
        else:
          "_zero"
      else:
        ""
    let adapterIdent = ident(typeName & "CborAdapter" & zeroAdapterTag)
    result.add(emitZeroArgAdapter(typeIdent, adapterIdent))
    registerCborRequestEntry(apiName & zeroApiSuffix, $adapterIdent, typeName, @[])

  # Arg-based adapter (suffixed when zero-arg also exists).
  if not sigs.argSig.isNil:
    let argAdapterTag = if not sigs.zeroArg.isNil: "Args" else: ""
    let argApiSuffix =
      if not sigs.zeroArg.isNil:
        let s = sigNameSuffix(sigs.argSigName)
        if s.len > 0:
          "_" & s
        else:
          "_args"
      else:
        ""
    let adapterIdent = ident(typeName & "CborAdapter" & argAdapterTag)
    let argsTypeIdent = ident(typeName & "CborArgs" & argAdapterTag)
    result.add(emitArgsType(argsTypeIdent, sigs.argParams))
    result.add(emitArgAdapter(typeIdent, adapterIdent, argsTypeIdent, sigs.argParams))
    let fields = paramFields(sigs.argParams)
    registerCborRequestEntry(apiName & argApiSuffix, $adapterIdent, typeName, fields)

  when defined(brokerDebug):
    echo "[brokers/cbor] RequestBroker(API) for '" & typeName & "' (apiName='" & apiName &
      "')"
    echo result.repr

{.pop.}

macro generateApiCborRequestBrokerDeferred*(args: varargs[untyped]): untyped =
  ## Typed-phase deferred codegen entry point. By the time this expands,
  ## any preceding `autoRegisterApiType` calls have already populated
  ## `gApiTypeRegistry`, so wrapper codegen can introspect external
  ## enum / distinct / object types without falling back to TODO stubs.
  ##
  ## Args layout: [body, kw0, kw1, ...]. Kwargs are forwarded as raw
  ## `nnkExprEqExpr` nodes from `generateApiCborRequestBroker` and
  ## re-parsed here into an MtReqCfg.
  if args.len == 0:
    error("generateApiCborRequestBrokerDeferred requires a body", args)
  let body = args[0]
  var kwargs: seq[NimNode]
  for i in 1 ..< args.len:
    kwargs.add(args[i])
  let cfg = parseMtReqKwargs(kwargs)
  generateApiCborRequestBrokerImpl(body, cfg)

{.push raises: [].}

proc generateApiCborRequestBroker*(body: NimNode, kwargs: seq[NimNode]): NimNode =
  ## Two-phase entry point — mirrors the native
  ## `generateApiRequestBroker` pattern. Kwargs are passed through the
  ## deferred macro call as raw nodes so the typed-phase expansion sees
  ## the original literal values for `parseMtReqKwargs`.
  result = newStmtList()

  let externalIdents = discoverExternalTypes(body)
  if externalIdents.len > 0:
    result.add(emitAutoRegistrations(externalIdents))

  let deferred =
    newCall(ident("generateApiCborRequestBrokerDeferred"), copyNimTree(body))
  for kw in kwargs:
    deferred.add(copyNimTree(kw))
  result.add(deferred)

{.pop.}
