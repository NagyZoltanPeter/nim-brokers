## API RequestBroker
## -----------------
## Generates a multi-thread capable RequestBroker with additional FFI glue code
## for exposing request signatures as C-callable exported functions.
##
## When compiled with `-d:BrokerFfiApi`, RequestBroker(API) generates:
## 1. All MT broker code (via generateMtRequestBroker)
## 2. C-compatible result struct for each request type
## 3. Exported C functions for each request signature
## 4. C header declarations appended to the compile-time accumulator
##
## When compiled without `-d:BrokerFfiApi`, falls back to MT mode.

{.push raises: [].}

import std/[macros, strutils]
import chronos, chronicles
import results
import ./helper/broker_utils, ../broker_context, ./mt_request_broker, ./api_common
import ./api_type_resolver

export results, chronos, chronicles, broker_context, mt_request_broker, api_common
export api_type_resolver

# ---------------------------------------------------------------------------
# Macro code generator
# ---------------------------------------------------------------------------

proc generateApiRequestBrokerImpl(body: NimNode): NimNode {.raises: [ValueError].} =
  ## Core codegen for API request broker. Called from `generateApiRequestBrokerDeferred`
  ## AFTER external types have been auto-registered, so `lookupFfiStruct` works.
  when defined(brokerDebug):
    echo body.treeRepr
    echo "RequestBroker mode: API"

  # Step 1: Parse type definition and signatures (same as MT)
  let parsed = parseSingleTypeDef(
    body, "RequestBroker", allowRefToNonObject = true, collectFieldInfo = true
  )
  let typeIdent = parsed.typeIdent
  let fieldNames = parsed.fieldNames
  let fieldTypes = parsed.fieldTypes
  let hasInlineFields = parsed.hasInlineFields

  let typeDisplayName = sanitizeIdentName(typeIdent)
  let snakeName = toSnakeCase(typeDisplayName)
  let hideFromForeignSurface = snakeName == "shutdown_request"
  let baseExportName =
    if snakeName.endsWith("_request"):
      let trimmed = snakeName[0 ..< snakeName.len - "_request".len]
      if trimmed == "shutdown": snakeName else: trimmed
    else:
      snakeName

  # Parse signatures (mirroring mt_request_broker logic)
  var zeroArgSig: NimNode = nil
  var argSig: NimNode = nil
  var zeroArgSigName = ""
  var argSigName = ""
  var argParams: seq[NimNode] = @[]

  proc signatureNameSuffix(sigName: string): string {.compileTime.} =
    if sigName.len <= "signature".len:
      return ""
    toSnakeCase(sigName["signature".len .. ^1])

  proc signaturePascalSuffix(sigName: string): string {.compileTime.} =
    ## PascalCase form of the part of `sigName` after the literal `signature`
    ## prefix. e.g. `signatureWithLabel` -> `WithLabel`, `signatureZero` ->
    ## `Zero`.
    if sigName.len <= "signature".len:
      return ""
    sigName["signature".len .. ^1]

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
      let paramCount = params.len - 1
      if paramCount == 0:
        zeroArgSig = stmt
        zeroArgSigName = $procNameIdent
      elif paramCount >= 1:
        argSig = stmt
        argSigName = $procNameIdent
        argParams = @[]
        for idx in 1 ..< params.len:
          argParams.add(copyNimTree(params[idx]))
    of nnkTypeSection, nnkEmpty:
      discard
    else:
      discard

  # If no signatures at all, default to zero-arg
  if zeroArgSig.isNil() and argSig.isNil():
    zeroArgSig = newEmptyNode()
    zeroArgSigName = "signature"

  let hasDualSignatures = not zeroArgSig.isNil() and not argSig.isNil()
  proc exportedFuncName(sigName: string): string {.compileTime.} =
    let sigSuffix = signatureNameSuffix(sigName)
    if hasDualSignatures and sigSuffix.len > 0:
      baseExportName & "_" & sigSuffix
    else:
      baseExportName

  # ---------------------------------------------------------------------------
  # Type classification helpers (used throughout codegen below)
  # ---------------------------------------------------------------------------

  proc isSeqOfPrimitiveNode(fType: NimNode): bool {.compileTime.} =
    ## True when fType is seq[T] where T is a primitive (includes string).
    if isSeqType(fType):
      return isNimPrimitive(seqItemTypeName(fType))
    false

  proc isSeqOfStringNode(fType: NimNode): bool {.compileTime.} =
    ## True when fType is seq[string] or seq[cstring].
    if isSeqType(fType):
      let elem = seqItemTypeName(fType).toLowerAscii()
      return elem in ["string", "cstring"]
    false

  proc isSeqOfObjectNode(fType: NimNode): bool {.compileTime.} =
    ## True when fType is seq[T] where T is a custom object (not primitive).
    if isSeqType(fType):
      return not isNimPrimitive(seqItemTypeName(fType))
    false

  proc isEnumNode(fType: NimNode): bool {.compileTime.} =
    ## True when fType is a registered enum type.
    if fType.kind == nnkIdent:
      return isEnumRegistered($fType)
    false

  proc isDistinctNode(fType: NimNode): bool {.compileTime.} =
    ## True when fType is a registered distinct type.
    if fType.kind == nnkIdent:
      for entry in gApiTypeRegistry:
        if entry.name == $fType and entry.kind == atkDistinct:
          return true
    false

  proc primElemCNimType(elemName: string): NimNode {.compileTime.} =
    ## Returns the C-compatible Nim type for a primitive element name.
    toCFieldType(ident(elemName))

  # ---------------------------------------------------------------------------
  # Decode helpers for seq input parameters
  # ---------------------------------------------------------------------------

  proc buildSeqDecodeStmt(
      paramName: string, itemTypeName: string, itemFields: seq[(string, string)]
  ): NimNode {.compileTime, raises: [ValueError].} =
    let countName = paramName & "_count"
    let arrName = "arr_" & paramName
    let idxName = "i_" & paramName
    let nimName = "nim_" & paramName
    var code = "var " & nimName & ": seq[" & itemTypeName & "] = @[]\n"
    code.add("if " & countName & " > 0 and not " & paramName & ".isNil:\n")
    code.add(
      "  let " & arrName & " = cast[ptr UncheckedArray[" & itemTypeName & "CItem]](" &
        paramName & ")\n"
    )
    code.add(
      "  " & nimName & " = newSeqOfCap[" & itemTypeName & "](int(" & countName & "))\n"
    )
    code.add("  for " & idxName & " in 0 ..< int(" & countName & "):\n")
    code.add("    " & nimName & ".add(" & itemTypeName & "(\n")
    for fieldIndex, (fieldName, fieldType) in itemFields:
      code.add("      " & fieldName & ": ")
      let fieldExpr = arrName & "[" & idxName & "]." & fieldName
      if fieldType.toLowerAscii() in ["string", "cstring"]:
        code.add("(if " & fieldExpr & ".isNil: \"\" else: $" & fieldExpr & ")")
      else:
        code.add(fieldExpr)
      if fieldIndex < itemFields.len - 1:
        code.add(",")
      code.add("\n")
    code.add("    ))")
    parseStmt(code)

  proc buildPrimitiveSeqDecodeStmt(
      paramName: string, elemTypeName: string
  ): NimNode {.compileTime, raises: [ValueError].} =
    ## Decode a seq[primitive] input: cast pointer to UncheckedArray, build seq.
    let countName = paramName & "_count"
    let arrName = "arr_" & paramName
    let idxName = "i_" & paramName
    let nimName = "nim_" & paramName
    let cElemType = $primElemCNimType(elemTypeName)
    var code = "var " & nimName & ": seq[" & elemTypeName & "] = @[]\n"
    code.add("if " & countName & " > 0 and not " & paramName & ".isNil:\n")
    code.add(
      "  let " & arrName & " = cast[ptr UncheckedArray[" & cElemType & "]](" & paramName &
        ")\n"
    )
    code.add(
      "  " & nimName & " = newSeqOfCap[" & elemTypeName & "](int(" & countName & "))\n"
    )
    code.add("  for " & idxName & " in 0 ..< int(" & countName & "):\n")
    code.add(
      "    " & nimName & ".add(" & elemTypeName & "(" & arrName & "[" & idxName & "]))\n"
    )
    parseStmt(code)

  proc buildStringSeqDecodeStmt(
      paramName: string
  ): NimNode {.compileTime, raises: [ValueError].} =
    ## Decode a seq[string] input: cast pointer to UncheckedArray[cstring], convert each.
    let countName = paramName & "_count"
    let arrName = "arr_" & paramName
    let idxName = "i_" & paramName
    let nimName = "nim_" & paramName
    var code = "var " & nimName & ": seq[string] = @[]\n"
    code.add("if " & countName & " > 0 and not " & paramName & ".isNil:\n")
    code.add(
      "  let " & arrName & " = cast[ptr UncheckedArray[cstring]](" & paramName & ")\n"
    )
    code.add("  " & nimName & " = newSeqOfCap[string](int(" & countName & "))\n")
    code.add("  for " & idxName & " in 0 ..< int(" & countName & "):\n")
    code.add(
      "    " & nimName & ".add(if " & arrName & "[" & idxName & "].isNil: \"\" else: $" &
        arrName & "[" & idxName & "])\n"
    )
    parseStmt(code)

  proc buildArrayDecodeStmt(
      paramName: string, elemTypeName: string, n: int
  ): NimNode {.compileTime, raises: [ValueError].} =
    ## Decode an array[N,T] input: cast pointer to ptr UncheckedArray and copyMem.
    let nimName = "nim_" & paramName
    let cElemType = $primElemCNimType(elemTypeName)
    var code =
      "var " & nimName & ": array[" & $n & ", " & elemTypeName & "] = default(array[" &
      $n & ", " & elemTypeName & "])\n"
    code.add("if not " & paramName & ".isNil:\n")
    code.add(
      "  let arr_" & paramName & " = cast[ptr UncheckedArray[" & cElemType & "]](" &
        paramName & ")\n"
    )
    code.add("  for i_" & paramName & " in 0 ..< " & $n & ":\n")
    code.add(
      "    " & nimName & "[i_" & paramName & "] = " & elemTypeName & "(arr_" & paramName &
        "[i_" & paramName & "])\n"
    )
    parseStmt(code)

  # ---------------------------------------------------------------------------
  # C++ param setup helpers
  # ---------------------------------------------------------------------------

  proc buildCppSeqParamSetup(
      paramName: string, itemTypeName: string, itemFields: seq[(string, string)]
  ): string {.compileTime.} =
    result = "        std::vector<" & itemTypeName & "CItem> " & paramName & "CItems;\n"
    result.add("        " & paramName & "CItems.reserve(" & paramName & ".size());\n")
    result.add("        for (const auto& item : " & paramName & ") {\n")
    result.add(
      "            " & paramName & "CItems.push_back(" & itemTypeName & "CItem{\n"
    )
    for fieldIndex, (fieldName, fieldType) in itemFields:
      result.add("                ")
      if fieldType.toLowerAscii() in ["string", "cstring"]:
        result.add("const_cast<char*>(item." & fieldName & ".c_str())")
      else:
        result.add("item." & fieldName)
      if fieldIndex < itemFields.len - 1:
        result.add(",")
      result.add("\n")
    result.add("            });\n")
    result.add("        }\n")

  proc buildCppStringSeqParamSetup(paramName: string): string {.compileTime.} =
    ## For seq[string] input: build temp std::vector<const char*> from .c_str().
    result = "        std::vector<const char*> " & paramName & "CStrs;\n"
    result.add("        " & paramName & "CStrs.reserve(" & paramName & ".size());\n")
    result.add("        for (const auto& s : " & paramName & ") {\n")
    result.add("            " & paramName & "CStrs.push_back(s.c_str());\n")
    result.add("        }\n")

  proc buildPySeqParamSetup(
      paramName: string, itemTypeName: string, itemFields: seq[(string, string)]
  ): string {.compileTime.} =
    result = "        " & paramName & "_items: list[" & itemTypeName & "CItem] = []\n"
    result.add("        " & paramName & "_refs: list[object] = []\n")
    result.add("        for _item in " & paramName & ":\n")
    for (fieldName, fieldType) in itemFields:
      if fieldType.toLowerAscii() in ["string", "cstring"]:
        let encodedName = "_" & paramName & "_" & fieldName
        result.add(
          "            " & encodedName & " = _item." & fieldName & ".encode(\"utf-8\")\n"
        )
        result.add("            " & paramName & "_refs.append(" & encodedName & ")\n")
    result.add(
      "            " & paramName & "_items.append(" & itemTypeName & "CItem(\n"
    )
    for fieldIndex, (fieldName, fieldType) in itemFields:
      result.add("                ")
      if fieldType.toLowerAscii() in ["string", "cstring"]:
        result.add("_" & paramName & "_" & fieldName)
      else:
        result.add("_item." & fieldName)
      if fieldIndex < itemFields.len - 1:
        result.add(",")
      result.add("\n")
    result.add("            ))\n")
    result.add(
      "        " & paramName & "_array = (" & itemTypeName & "CItem * len(" & paramName &
        "_items))(*" & paramName & "_items) if " & paramName & "_items else None\n"
    )

  proc buildPyStringSeqParamSetup(paramName: string): string {.compileTime.} =
    result =
      "        " & paramName & "_encoded = [s.encode('utf-8') for s in " & paramName &
      "]\n"
    result.add(
      "        " & paramName & "_arr_type = ctypes.c_char_p * len(" & paramName &
        "_encoded)\n"
    )
    result.add(
      "        " & paramName & "_ptr = " & paramName & "_arr_type(*" & paramName &
        "_encoded) if " & paramName & "_encoded else None\n"
    )

  proc buildPyPrimSeqParamSetup(paramName, ctElem: string): string {.compileTime.} =
    result =
      "        " & paramName & "_arr_type = " & ctElem & " * len(" & paramName & ")\n"
    result.add(
      "        " & paramName & "_ptr = " & paramName & "_arr_type(*" & paramName &
        ") if " & paramName & " else None\n"
    )

  proc buildPyArrayParamSetup(
      paramName, ctElem: string, n: int
  ): string {.compileTime.} =
    result =
      "        " & paramName & "_arr = (" & ctElem & " * " & $n & ")(*" & paramName &
      ")\n"

  # ---------------------------------------------------------------------------
  # Step 2: Generate all MT broker code
  # ---------------------------------------------------------------------------
  result = newStmtList()

  result.add(generateMtRequestBroker(body))

  # Step 2b: Emit foreign thread GC helper (once per compilation unit)
  result.add(emitEnsureForeignThreadGc())

  # Step 2c: Generate per-type provider cleanup proc
  let cleanupProcName = "cleanupApiRequestProvider_" & typeDisplayName
  let cleanupProcIdent = ident(cleanupProcName)
  let cleanupCtxIdent = genSym(nskParam, "ctx")
  result.add(
    quote do:
      proc `cleanupProcIdent`(`cleanupCtxIdent`: BrokerContext) =
        `typeIdent`.clearProvider(`cleanupCtxIdent`)

  )
  gApiRequestCleanupProcNames.add(cleanupProcName)

  # ---------------------------------------------------------------------------
  # Step 3: Generate C result struct type (Nim side with exportc)
  # ---------------------------------------------------------------------------
  let cResultIdent = ident(typeDisplayName & "CResult")
  let exportedCResultIdent = postfix(copyNimTree(cResultIdent), "*")

  var cResultFields = newTree(nnkRecList)
  # error_message field (NULL on success)
  cResultFields.add(
    newTree(
      nnkIdentDefs,
      postfix(ident("error_message"), "*"),
      ident("cstring"),
      newEmptyNode(),
    )
  )

  # Add result fields (mapped to C-compatible types)
  # seq[T] expands to pointer + cint count; array[N,T] stays as array[N,cType];
  # Option[T] expands to <name>: T + <name>_has_value: bool (uniform layout).
  if hasInlineFields:
    for i in 0 ..< fieldNames.len:
      let fType = fieldTypes[i]
      if isSeqType(fType):
        # All seq[T] (primitive, string, object) → pointer + count
        cResultFields.add(
          newTree(
            nnkIdentDefs,
            postfix(copyNimTree(fieldNames[i]), "*"),
            ident("pointer"),
            newEmptyNode(),
          )
        )
        cResultFields.add(
          newTree(
            nnkIdentDefs,
            postfix(ident($fieldNames[i] & "_count"), "*"),
            ident("cint"),
            newEmptyNode(),
          )
        )
      elif isOptionType(fType):
        # Phase E1 (scalar): emit value field of unwrapped T plus a sibling
        # `<name>_has_value: bool`. The encode proc populates both from
        # the Nim Option's some/none state. Layout X (uniform) — every
        # Option emits the bool sibling regardless of whether the value
        # type is variable-shape; that comes in phases E2/E3.
        let inner = optionInnerType(fType)
        let cFieldType = toCFieldType(inner)
        cResultFields.add(
          newTree(
            nnkIdentDefs,
            postfix(copyNimTree(fieldNames[i]), "*"),
            cFieldType,
            newEmptyNode(),
          )
        )
        cResultFields.add(
          newTree(
            nnkIdentDefs,
            postfix(ident($fieldNames[i] & optionHasValueSuffix), "*"),
            ident("bool"),
            newEmptyNode(),
          )
        )
      else:
        # array[N,T] → array[N, cType]; enum → cint; string → cstring; etc.
        let cFieldType = toCFieldType(fType)
        cResultFields.add(
          newTree(
            nnkIdentDefs,
            postfix(copyNimTree(fieldNames[i]), "*"),
            cFieldType,
            newEmptyNode(),
          )
        )

  result.add(
    quote do:
      type `exportedCResultIdent` {.exportc.} = object
  )
  # Replace the empty RecList with our fields
  let lastTypeSect = result[result.len - 1]
  for typeDef in lastTypeSect:
    if typeDef.kind == nnkTypeDef:
      let objTy = typeDef[2]
      if objTy.kind == nnkObjectTy:
        objTy[2] = cResultFields

  # ---------------------------------------------------------------------------
  # Step 4: Generate encode proc (Nim object → C result struct)
  # ---------------------------------------------------------------------------
  #
  # The encode proc converts the Nim result object into the flat C-ABI struct.
  # Every pointer field it sets is allocated on the shared heap so the result
  # can safely cross the Nim GC boundary and be read by foreign code on any
  # thread. The free_result function generated in Step 4b frees exactly the
  # memory allocated here — they must stay in sync.
  let encodeProcIdent = ident("encode" & typeDisplayName & "ToC")
  let objIdent = ident("obj")
  var hasSeqFields = false
  if hasInlineFields:
    var encodeBody = newStmtList()
    for i in 0 ..< fieldNames.len:
      let fName = fieldNames[i]
      let fType = fieldTypes[i]
      if isSeqOfStringNode(fType):
        # seq[string]: allocate array of cstring pointers, copy-allocate each
        hasSeqFields = true
        let countFieldIdent = ident($fName & "_count")
        let nIdent = genSym(nskLet, "n")
        let arrIdent = genSym(nskLet, "arr")
        let iIdent = genSym(nskForVar, "i")
        encodeBody.add(
          quote do:
            let `nIdent` = `objIdent`.`fName`.len
            result.`countFieldIdent` = cint(`nIdent`)
            if `nIdent` > 0:
              let `arrIdent` = cast[ptr UncheckedArray[cstring]](allocShared(
                `nIdent` * sizeof(cstring)
              ))
              for `iIdent` in 0 ..< `nIdent`:
                `arrIdent`[`iIdent`] = allocCStringCopy(`objIdent`.`fName`[`iIdent`])
              result.`fName` = cast[pointer](`arrIdent`)
        )
      elif isSeqOfPrimitiveNode(fType):
        # seq[primitive]: allocate raw array and copy elements
        hasSeqFields = true
        let elemName = seqItemTypeName(fType)
        let primCNimType = primElemCNimType(elemName)
        let countFieldIdent = ident($fName & "_count")
        let nIdent = genSym(nskLet, "n")
        let arrIdent = genSym(nskLet, "arr")
        let iIdent = genSym(nskForVar, "i")
        encodeBody.add(
          quote do:
            let `nIdent` = `objIdent`.`fName`.len
            result.`countFieldIdent` = cint(`nIdent`)
            if `nIdent` > 0:
              let `arrIdent` = cast[ptr UncheckedArray[`primCNimType`]](allocShared(
                `nIdent` * sizeof(`primCNimType`)
              ))
              for `iIdent` in 0 ..< `nIdent`:
                `arrIdent`[`iIdent`] = `primCNimType`(`objIdent`.`fName`[`iIdent`])
              result.`fName` = cast[pointer](`arrIdent`)
        )
      elif isSeqOfObjectNode(fType):
        # seq[object]: existing CItem encode
        hasSeqFields = true
        let itemTypeName = seqItemTypeName(fType)
        let cItemIdent = ident(itemTypeName & "CItem")
        let encodeFuncIdent = ident("encode" & itemTypeName & "ToCItem")
        let countFieldIdent = ident($fName & "_count")
        let nIdent = genSym(nskLet, "n")
        let arrIdent = genSym(nskLet, "arr")
        let iIdent = genSym(nskForVar, "i")
        encodeBody.add(
          quote do:
            let `nIdent` = `objIdent`.`fName`.len
            result.`countFieldIdent` = cint(`nIdent`)
            if `nIdent` > 0:
              let `arrIdent` = cast[ptr UncheckedArray[`cItemIdent`]](allocShared(
                `nIdent` * sizeof(`cItemIdent`)
              ))
              for `iIdent` in 0 ..< `nIdent`:
                `arrIdent`[`iIdent`] = `encodeFuncIdent`(`objIdent`.`fName`[`iIdent`])
              result.`fName` = cast[pointer](`arrIdent`)
        )
      elif isEnumNode(fType):
        # enum: ord() cast to cint
        encodeBody.add(
          quote do:
            result.`fName` = cint(ord(`objIdent`.`fName`))
        )
      elif isCStringType(fType):
        encodeBody.add(
          quote do:
            result.`fName` = allocCStringCopy(`objIdent`.`fName`)
        )
      elif isDistinctNode(fType):
        # distinct type: cast through underlying type to match C field type
        let cFieldTypeNode = toCFieldType(fType)
        encodeBody.add(
          quote do:
            result.`fName` = cast[`cFieldTypeNode`](`objIdent`.`fName`)
        )
      elif isArrayTypeNode(fType):
        # array[N,T]: direct field copy (works for primitive element types)
        # For array[N, string] we'd need element-wise alloc, but that's rare
        encodeBody.add(
          quote do:
            result.`fName` = `objIdent`.`fName`
        )
      elif isOptionType(fType):
        # Phase E1 (scalar): emit `if v.x.isSome: c.x = v.x.get; c.x_has_value =
        # true else: c.x = default(T); c.x_has_value = false`. The default
        # value when absent is whatever Nim's default(T) returns — for the
        # C side it doesn't matter what's in the value field when has_value
        # is false; readers must consult has_value first.
        let hasValueIdent = ident($fName & optionHasValueSuffix)
        let inner = optionInnerType(fType)
        let cInnerType = toCFieldType(inner)
        encodeBody.add(
          quote do:
            if `objIdent`.`fName`.isSome():
              result.`fName` = cast[`cInnerType`](`objIdent`.`fName`.get())
              result.`hasValueIdent` = true
            else:
              result.`fName` = default(`cInnerType`)
              result.`hasValueIdent` = false
        )
      else:
        encodeBody.add(
          quote do:
            result.`fName` = `objIdent`.`fName`
        )

    result.add(
      quote do:
        proc `encodeProcIdent`(`objIdent`: `typeIdent`): `cResultIdent` =
          `encodeBody`

    )
  else:
    result.add(
      quote do:
        proc `encodeProcIdent`(`objIdent`: `typeIdent`): `cResultIdent` =
          discard

    )

  # ---------------------------------------------------------------------------
  # Step 4b: Generate free_result function
  # ---------------------------------------------------------------------------
  #
  # Memory model for request results
  # ----------------------------------
  # The encode proc (Step 4a) allocates all heap memory needed to represent the
  # Nim result as a flat C struct. The generated free_<type>_result function
  # mirrors that allocation exactly — it must free every pointer the encode proc
  # set, in the same order, before returning. The foreign caller is responsible
  # for calling free_<type>_result exactly once after it has finished reading the
  # struct. C++ and Python wrappers call it automatically via RAII / finally.
  #
  # Field-type free strategies:
  #
  #   error_message   — always freed first; freeCString (may be nil, checked).
  #
  #   string field    — freeCString(r->field)  [allocated by allocCStringCopy]
  #
  #   seq[string]     — if count > 0 and pointer not nil:
  #                       for each element: freeCString(arr[i])  (element copies)
  #                       deallocShared(r->field)                (pointer array)
  #                     Two-level free: inner strings then outer array.
  #
  #   seq[primitive]  — if count > 0 and pointer not nil:
  #                       deallocShared(r->field)
  #                     Single-level free: elements are value types, no per-element
  #                     cleanup needed.
  #
  #   seq[object]     — if count > 0 and pointer not nil:
  #                       for each CItem: freeCString any cstring fields inside it
  #                       deallocShared(r->field)
  #                     Two-level free: inner strings then outer CItem array.
  #
  #   array[N, T]     — inline in the struct; no pointer, nothing to free.
  #
  #   enum / primitive / distinct — value fields; nothing to free.
  block:
    let freeProcName = "free_" & baseExportName & "_result"
    let freeProcIdent = ident(freeProcName)
    let freeProcNameLit = newLit(freeProcName)
    let rIdent = ident("r")

    var freeBody = newStmtList()
    # Free error_message
    freeBody.add(
      quote do:
        if not `rIdent`.error_message.isNil:
          freeCString(`rIdent`.error_message)
    )

    if hasInlineFields:
      for i in 0 ..< fieldNames.len:
        let fName = fieldNames[i]
        let fType = fieldTypes[i]
        if isSeqOfStringNode(fType):
          # seq[string]: free each cstring, then the array
          let countFieldIdent = ident($fName & "_count")
          let arrIdent = genSym(nskLet, "arr")
          let jIdent = genSym(nskForVar, "j")
          freeBody.add(
            quote do:
              if `rIdent`.`countFieldIdent` > 0 and not `rIdent`.`fName`.isNil:
                let `arrIdent` = cast[ptr UncheckedArray[cstring]](`rIdent`.`fName`)
                for `jIdent` in 0 ..< `rIdent`.`countFieldIdent`:
                  if not `arrIdent`[`jIdent`].isNil:
                    freeCString(`arrIdent`[`jIdent`])
                deallocShared(`rIdent`.`fName`)
          )
        elif isSeqOfPrimitiveNode(fType):
          # seq[primitive]: just free the array (no per-element cleanup needed)
          let countFieldIdent = ident($fName & "_count")
          freeBody.add(
            quote do:
              if `rIdent`.`countFieldIdent` > 0 and not `rIdent`.`fName`.isNil:
                deallocShared(`rIdent`.`fName`)
          )
        elif isSeqOfObjectNode(fType):
          # seq[object]: free string fields inside each CItem, then the array
          let itemTypeName = seqItemTypeName(fType)
          let itemFields = lookupFfiStruct(itemTypeName)
          let countFieldIdent = ident($fName & "_count")
          let arrIdent = genSym(nskLet, "arr")
          let cItemIdent = ident(itemTypeName & "CItem")
          let jIdent = genSym(nskForVar, "j")

          var itemFreeStmts = newStmtList()
          for (ifName, ifType) in itemFields:
            if ifType.toLowerAscii() in ["string", "cstring"]:
              let ifNameIdent = ident(ifName)
              itemFreeStmts.add(
                quote do:
                  if not `arrIdent`[`jIdent`].`ifNameIdent`.isNil:
                    freeCString(`arrIdent`[`jIdent`].`ifNameIdent`)
              )

          freeBody.add(
            quote do:
              if `rIdent`.`countFieldIdent` > 0 and not `rIdent`.`fName`.isNil:
                let `arrIdent` =
                  cast[ptr UncheckedArray[`cItemIdent`]](`rIdent`.`fName`)
                for `jIdent` in 0 ..< `rIdent`.`countFieldIdent`:
                  `itemFreeStmts`
                deallocShared(`rIdent`.`fName`)
          )
        elif isCStringType(fType):
          freeBody.add(
            quote do:
              if not `rIdent`.`fName`.isNil:
                freeCString(`rIdent`.`fName`)
          )
        # enum, primitive, array[N,T] with primitive elements: nothing to free

    result.add(
      quote do:
        proc `freeProcIdent`(
            `rIdent`: ptr `cResultIdent`
        ) {.exportc: `freeProcNameLit`, cdecl, dynlib.} =
          if `rIdent`.isNil:
            return
          `freeBody`

    )

  # Saved for Step 7: will be appended AFTER struct declaration in header
  var freeHeaderProto = ""
  var cppFreeMethod = ""

  # Step 4b continued: save header declarations for later
  block:
    let freeProcName2 = "free_" & baseExportName & "_result"
    let publicFreeProcName = apiPublicCName(freeProcName2)
    if not hideFromForeignSurface:
      freeHeaderProto = generateCFuncProto(
        publicFreeProcName, "void", @[("r", typeDisplayName & "CResult*")]
      )
      cppFreeMethod =
        "void free" & typeDisplayName & "Result(" & typeDisplayName & "CResult* r) { " &
        publicFreeProcName & "(r); }"
      registerApiCExportWrapper(
        freeProcName2,
        freeProcName2,
        "void",
        @[("r", "ptr " & typeDisplayName & "CResult")],
      )

  # ---------------------------------------------------------------------------
  # Helper: build C header fields for a result/input type
  # ---------------------------------------------------------------------------

  proc buildCHeaderFields(
      fNames: seq[NimNode], fTypes: seq[NimNode], forOutput: bool
  ): seq[(string, string)] {.compileTime.} =
    for i in 0 ..< fNames.len:
      let fType = fTypes[i]
      if isSeqOfStringNode(fType):
        # seq[string] → char** + count
        if forOutput:
          result.add(($fNames[i], "char**"))
        else:
          result.add(($fNames[i], "const char**"))
        result.add(($fNames[i] & "_count", "int32_t"))
      elif isSeqOfPrimitiveNode(fType):
        # seq[primitive] → primType* + count
        let elemName = seqItemTypeName(fType)
        let cType = nimTypeToCSuffix(ident(elemName))
        if forOutput:
          result.add(($fNames[i], cType & "*"))
        else:
          result.add(($fNames[i], "const " & cType & "*"))
        result.add(($fNames[i] & "_count", "int32_t"))
      elif isSeqType(fType):
        # seq[object] → CItem* + count
        let itemTypeName = seqItemTypeName(fType)
        result.add(($fNames[i], itemTypeName & "CItem*"))
        result.add(($fNames[i] & "_count", "int32_t"))
      elif isArrayTypeNode(fType):
        # array[N, T] → encoded as "elemType[N]", generateCStruct handles layout
        let cType = nimTypeToCSuffix(fType) # returns "elemType[N]"
        result.add(($fNames[i], cType))
      elif isOptionType(fType):
        # Option[T] → <name>: T + <name>_has_value: bool (uniform layout).
        let inner = optionInnerType(fType)
        let cType =
          if forOutput:
            nimTypeToCOutput(inner)
          else:
            nimTypeToCInput(inner)
        result.add(($fNames[i], cType))
        result.add(($fNames[i] & optionHasValueSuffix, "bool"))
      elif forOutput:
        result.add(($fNames[i], nimTypeToCOutput(fType)))
      else:
        result.add(($fNames[i], nimTypeToCInput(fType)))

  # ---------------------------------------------------------------------------
  # Step 5: Generate C-exported request functions
  # ---------------------------------------------------------------------------

  # Zero-arg signature
  if not zeroArgSig.isNil():
    let funcName = exportedFuncName(zeroArgSigName)
    let publicFuncName = apiPublicCName(funcName)
    let funcIdent = ident(funcName)
    let funcNameLit = newLit(funcName)

    result.add(
      quote do:
        proc `funcIdent`(
            ctx: uint32
        ): `cResultIdent` {.exportc: `funcNameLit`, cdecl, dynlib.} =
          ensureForeignThreadGc()
          let brokerCtx = BrokerContext(ctx)
          # Use the blocking (busy-poll) variant on the foreign caller's
          # thread, NOT `waitFor request(...)`. Driving chronos on a thread
          # that doesn't own an event loop spawns a persistent
          # brokerDispatchLoop coroutine + suspended `signal.wait()` future
          # whose state accumulates across FFI calls; under refc that
          # eventually corrupts the thread's GC heap (PR #13, macos-amd64
          # ASAN). The arg-bearing FFI request entries already use
          # blockingRequest for the same reason. Keeps subscribe / on / off
          # / shutdown / request all on the same allocation-free
          # synchronous response-slot polling path on the caller's thread.
          let res = blockingRequest(`typeIdent`, brokerCtx)
          if res.isOk():
            return `encodeProcIdent`(res.get())
          else:
            var errResult: `cResultIdent`
            errResult.error_message = allocCStringCopy(res.error())
            return errResult

    )

    # Append header declarations
    var headerFields: seq[(string, string)] = @[("error_message", "char*")]
    if hasInlineFields:
      headerFields.add(buildCHeaderFields(fieldNames, fieldTypes, forOutput = true))
    let structDecl = generateCStruct(typeDisplayName & "CResult", headerFields)
    if not hideFromForeignSurface:
      appendHeaderDecl(structDecl)

    let funcProto = generateCFuncProto(
      publicFuncName, typeDisplayName & "CResult", @[("ctx", "uint32_t")]
    )
    if not hideFromForeignSurface:
      appendHeaderDecl(funcProto)
      registerApiCExportWrapper(
        funcName, funcName, typeDisplayName & "CResult", @[("ctx", "uint32")]
      )

  # Arg-based signature
  if not argSig.isNil():
    let funcName = exportedFuncName(argSigName)
    let publicFuncName = apiPublicCName(funcName)
    let funcIdent = ident(funcName)
    let funcNameLit = newLit(funcName)

    # Build C function parameters
    var cFormalParams = newTree(nnkFormalParams)
    cFormalParams.add(copyNimTree(newTree(nnkBracketExpr))) # placeholder
    cFormalParams[0] = ident($cResultIdent) # return type

    cFormalParams.add(
      newTree(nnkIdentDefs, ident("ctx"), ident("uint32"), newEmptyNode())
    )

    # Add C-compatible versions of each signature param
    var decodeStmts = newStmtList()
    var nimCallArgs: seq[NimNode] = @[]
    var headerParams: seq[(string, string)] = @[("ctx", "uint32_t")]
    var wrapperParams: seq[(string, string)] = @[("ctx", "uint32")]

    for paramDef in argParams:
      for i in 0 ..< paramDef.len - 2:
        let paramName = paramDef[i]
        let paramType = paramDef[paramDef.len - 2]
        let paramNameStr = $paramName

        if isSeqOfStringNode(paramType):
          # seq[string] → const char** + cint count
          let cParamIdent = ident(paramNameStr)
          let countIdent = ident(paramNameStr & "_count")
          cFormalParams.add(
            newTree(nnkIdentDefs, cParamIdent, ident("pointer"), newEmptyNode())
          )
          cFormalParams.add(
            newTree(nnkIdentDefs, countIdent, ident("cint"), newEmptyNode())
          )
          decodeStmts.add(buildStringSeqDecodeStmt(paramNameStr))
          nimCallArgs.add(ident("nim_" & paramNameStr))
          headerParams.add((paramNameStr, "const char**"))
          headerParams.add((paramNameStr & "_count", "int32_t"))
          wrapperParams.add((paramNameStr, "pointer"))
          wrapperParams.add((paramNameStr & "_count", "cint"))
        elif isSeqOfPrimitiveNode(paramType):
          # seq[primitive] → pointer + cint count
          let elemName = seqItemTypeName(paramType)
          let cParamIdent = ident(paramNameStr)
          let countIdent = ident(paramNameStr & "_count")
          cFormalParams.add(
            newTree(nnkIdentDefs, cParamIdent, ident("pointer"), newEmptyNode())
          )
          cFormalParams.add(
            newTree(nnkIdentDefs, countIdent, ident("cint"), newEmptyNode())
          )
          decodeStmts.add(buildPrimitiveSeqDecodeStmt(paramNameStr, elemName))
          nimCallArgs.add(ident("nim_" & paramNameStr))
          let cElemType = nimTypeToCSuffix(ident(elemName))
          headerParams.add((paramNameStr, "const " & cElemType & "*"))
          headerParams.add((paramNameStr & "_count", "int32_t"))
          wrapperParams.add((paramNameStr, "pointer"))
          wrapperParams.add((paramNameStr & "_count", "cint"))
        elif isSeqType(paramType):
          # seq[object] — existing CItem path
          let itemTypeName = seqItemTypeName(paramType)
          let cParamIdent = ident(paramNameStr)
          let countIdent = ident(paramNameStr & "_count")

          cFormalParams.add(
            newTree(nnkIdentDefs, cParamIdent, ident("pointer"), newEmptyNode())
          )
          cFormalParams.add(
            newTree(nnkIdentDefs, countIdent, ident("cint"), newEmptyNode())
          )

          decodeStmts.add(
            buildSeqDecodeStmt(
              paramNameStr, itemTypeName, lookupFfiStruct(itemTypeName)
            )
          )
          nimCallArgs.add(ident("nim_" & paramNameStr))

          headerParams.add((paramNameStr, itemTypeName & "CItem*"))
          headerParams.add((paramNameStr & "_count", "int32_t"))
          wrapperParams.add((paramNameStr, "pointer"))
          wrapperParams.add((paramNameStr & "_count", "cint"))
        elif isArrayTypeNode(paramType):
          # array[N, T] → pass as pointer, decode on Nim side
          let n = arrayNodeSize(paramType)
          let elemName = arrayNodeElemName(paramType)
          let cParamIdent = ident(paramNameStr)
          cFormalParams.add(
            newTree(nnkIdentDefs, cParamIdent, ident("pointer"), newEmptyNode())
          )
          decodeStmts.add(buildArrayDecodeStmt(paramNameStr, elemName, n))
          nimCallArgs.add(ident("nim_" & paramNameStr))
          let cElemType = nimTypeToCSuffix(ident(elemName))
          headerParams.add((paramNameStr, "const " & cElemType & "*"))
          wrapperParams.add((paramNameStr, "pointer"))
        else:
          # scalar types (including enums)
          let cParamType = toCFieldType(paramType)
          let cParamIdent = ident(paramNameStr)

          cFormalParams.add(
            newTree(nnkIdentDefs, cParamIdent, cParamType, newEmptyNode())
          )

          if isCStringType(paramType):
            let nimParamIdent = ident("nim_" & paramNameStr)
            decodeStmts.add(
              quote do:
                let `nimParamIdent` = $`cParamIdent`
            )
            nimCallArgs.add(nimParamIdent)
          elif isEnumNode(paramType):
            # enum param: cast from cint to enum type
            let nimParamIdent = ident("nim_" & paramNameStr)
            decodeStmts.add(
              quote do:
                let `nimParamIdent` = `paramType`(`cParamIdent`)
            )
            nimCallArgs.add(nimParamIdent)
          elif isAliasOrDistinctRegistered($paramType):
            # distinct/alias param: wrap C value in the Nim distinct type
            let nimParamIdent = ident("nim_" & paramNameStr)
            decodeStmts.add(
              quote do:
                let `nimParamIdent` = `paramType`(`cParamIdent`)
            )
            nimCallArgs.add(nimParamIdent)
          else:
            nimCallArgs.add(cParamIdent)

          headerParams.add((paramNameStr, nimTypeToCInput(paramType)))
          wrapperParams.add((paramNameStr, $cParamType))

    # Build the request call with decoded args
    let brokerCtxIdent = ident("brokerCtx")
    var requestCall =
      newCall(ident("blockingRequest"), copyNimTree(typeIdent), brokerCtxIdent)
    for arg in nimCallArgs:
      requestCall.add(arg)

    var funcBody = newStmtList()
    funcBody.add(
      quote do:
        ensureForeignThreadGc()
    )
    funcBody.add(
      quote do:
        let `brokerCtxIdent` = BrokerContext(ctx)
    )
    funcBody.add(decodeStmts)
    funcBody.add(
      quote do:
        let res = `requestCall`
        if res.isOk():
          return `encodeProcIdent`(res.get())
        else:
          var errResult: `cResultIdent`
          errResult.error_message = allocCStringCopy(res.error())
          return errResult
    )

    # Build the exported proc
    let pragmas = newTree(
      nnkPragma,
      newTree(nnkExprColonExpr, ident("exportc"), funcNameLit),
      ident("cdecl"),
      ident("dynlib"),
    )

    cFormalParams[0] = ident($cResultIdent)

    let funcProc = newTree(
      nnkProcDef,
      postfix(funcIdent, "*"),
      newEmptyNode(),
      newEmptyNode(),
      cFormalParams,
      pragmas,
      newEmptyNode(),
      funcBody,
    )
    result.add(funcProc)

    # If we haven't already added the struct (from zero-arg), add it now
    if zeroArgSig.isNil():
      var headerFields: seq[(string, string)] = @[("error_message", "char*")]
      if hasInlineFields:
        headerFields.add(buildCHeaderFields(fieldNames, fieldTypes, forOutput = true))
      let structDecl = generateCStruct(typeDisplayName & "CResult", headerFields)
      if not hideFromForeignSurface:
        appendHeaderDecl(structDecl)

    let funcProto =
      generateCFuncProto(publicFuncName, typeDisplayName & "CResult", headerParams)
    if not hideFromForeignSurface:
      appendHeaderDecl(funcProto)
      registerApiCExportWrapper(
        funcName, funcName, typeDisplayName & "CResult", wrapperParams
      )

  # ---------------------------------------------------------------------------
  # Step 6: Generate C++ payload struct + class methods (declarations + defs)
  # ---------------------------------------------------------------------------
  let freeFuncName = apiPublicCName("free_" & baseExportName & "_result")
  let cppCls = "__CPP_CLASS__"

  var camelName = typeDisplayName
  if camelName.len > 0:
    camelName[0] = chr(ord(camelName[0]) + 32 * ord(camelName[0] in {'A' .. 'Z'}))

  # 6a: Plain payload struct (data only, no ctor) + forward decl + adopt()
  block:
    if not hideFromForeignSurface:
      let cppName = typeDisplayName
      let cResultName = typeDisplayName & "CResult"

      gApiCppForwardDecls.add("struct " & cppName & ";")

      var cppStruct = "struct " & cppName & " {\n"
      if hasInlineFields:
        for i in 0 ..< fieldNames.len:
          let fName = $fieldNames[i]
          let fType = fieldTypes[i]
          let cppType = nimTypeToCpp(fType)
          cppStruct.add("    " & cppType & " " & fName)
          if cppType in ["bool"]:
            cppStruct.add(" = false")
          elif cppType in [
            "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t",
            "uint32_t", "uint64_t", "float", "double",
          ]:
            cppStruct.add(" = 0")
          cppStruct.add(";\n")
      cppStruct.add("};\n")
      gApiCppStructs.add(cppStruct)

      # detail::adopt<Name>(<Name>CResult& c) -> <Name>
      var adopt =
        "inline " & cppName & " adopt" & cppName & "(::" & cResultName & "& c) {\n"
      adopt.add("    " & cppName & " r;\n")
      if hasInlineFields:
        for i in 0 ..< fieldNames.len:
          let fName = $fieldNames[i]
          let fType = fieldTypes[i]
          if isCStringType(fType):
            adopt.add(
              "    r." & fName & " = c." & fName & " ? c." & fName & " : \"\";\n"
            )
          elif isSeqOfStringNode(fType):
            let countField = fName & "_count"
            adopt.add("    if (c." & fName & " && c." & countField & " > 0) {\n")
            adopt.add("        auto* arr = static_cast<char**>(c." & fName & ");\n")
            adopt.add("        r." & fName & ".reserve(c." & countField & ");\n")
            adopt.add("        for (int32_t i = 0; i < c." & countField & "; ++i)\n")
            adopt.add(
              "            r." & fName & ".emplace_back(arr[i] ? arr[i] : \"\");\n"
            )
            adopt.add("    }\n")
          elif isSeqOfPrimitiveNode(fType):
            let elemName = seqItemTypeName(fType)
            let cppElemType = nimTypeToCpp(ident(elemName))
            let countField = fName & "_count"
            adopt.add("    if (c." & fName & " && c." & countField & " > 0) {\n")
            adopt.add(
              "        auto* arr = static_cast<" & cppElemType & "*>(c." & fName & ");\n"
            )
            adopt.add(
              "        r." & fName & ".assign(arr, arr + c." & countField & ");\n"
            )
            adopt.add("    }\n")
          elif isSeqOfObjectNode(fType):
            let itemTypeName = seqItemTypeName(fType)
            let countField = fName & "_count"
            adopt.add("    if (c." & fName & " && c." & countField & " > 0) {\n")
            adopt.add(
              "        auto* arr = static_cast<::" & itemTypeName & "CItem*>(c." & fName &
                ");\n"
            )
            adopt.add("        r." & fName & ".reserve(c." & countField & ");\n")
            adopt.add("        for (int32_t i = 0; i < c." & countField & "; ++i)\n")
            adopt.add(
              "            r." & fName & ".emplace_back(adopt" & itemTypeName &
                "(arr[i]));\n"
            )
            adopt.add("    }\n")
          elif isArrayTypeNode(fType):
            let n = arrayNodeSize(fType)
            adopt.add(
              "    std::copy(c." & fName & ", c." & fName & " + " & $n & ", r." & fName &
                ".begin());\n"
            )
          elif isEnumNode(fType):
            let enumTypeName = $fType
            adopt.add(
              "    r." & fName & " = static_cast<" & enumTypeName & ">(c." & fName &
                ");\n"
            )
          elif isOptionType(fType):
            # Option[T]: read sibling has_value flag → std::optional.
            let inner = optionInnerType(fType)
            let cppInner = nimTypeToCpp(inner)
            adopt.add(
              "    r." & fName & " = c." & fName & optionHasValueSuffix &
                " ? std::optional<" & cppInner & ">(c." & fName & ") : std::nullopt;\n"
            )
          else:
            adopt.add("    r." & fName & " = c." & fName & ";\n")
      adopt.add("    " & freeFuncName & "(&c);\n")
      adopt.add("    return r;\n")
      adopt.add("}\n")
      gApiCppDetailAdopters.add(adopt)

  # 6b: Method declarations (inside class) + inline definitions (after class)
  let cppRetTy = "Result<" & typeDisplayName & ">"

  if not hideFromForeignSurface and not zeroArgSig.isNil():
    let funcName = apiPublicCName(exportedFuncName(zeroArgSigName))
    gApiCppMethodDecls.add(cppRetTy & " " & camelName & "();")

    var def = "inline " & cppRetTy & " " & cppCls & "::" & camelName & "() {\n"
    def.add("    auto c = " & funcName & "(ctx_);\n")
    def.add("    if (c.error_message) {\n")
    def.add("        std::string err(c.error_message);\n")
    def.add("        " & freeFuncName & "(&c);\n")
    def.add("        return " & cppRetTy & "(std::move(err));\n")
    def.add("    }\n")
    def.add("    return " & cppRetTy & "(detail::adopt" & typeDisplayName & "(c));\n")
    def.add("}")
    gApiCppMethodDefs.add(def)

  if not hideFromForeignSurface and not argSig.isNil():
    let funcName = apiPublicCName(exportedFuncName(argSigName))
    var cppParams: seq[string] = @[]
    var cppCallArgs = "ctx_"
    var cppPreCall = ""
    for paramDef in argParams:
      for i in 0 ..< paramDef.len - 2:
        let paramName = $paramDef[i]
        let paramType = paramDef[paramDef.len - 2]
        let cppParamType =
          if isSeqOfStringNode(paramType):
            "const std::vector<std::string>&"
          elif isSeqOfPrimitiveNode(paramType):
            let elemName = seqItemTypeName(paramType)
            "const std::vector<" & nimTypeToCpp(ident(elemName)) & ">&"
          elif isSeqOfObjectNode(paramType):
            "const std::vector<" & seqItemTypeName(paramType) & ">&"
          elif isArrayTypeNode(paramType):
            "const " & nimTypeToCpp(paramType) & "&"
          else:
            nimTypeToCppParam(paramType)
        cppParams.add(cppParamType & " " & paramName)

        if isSeqOfStringNode(paramType):
          cppPreCall.add(buildCppStringSeqParamSetup(paramName))
          cppCallArgs.add(
            ", " & paramName & "CStrs.empty() ? nullptr : " & paramName & "CStrs.data()"
          )
          cppCallArgs.add(", static_cast<int32_t>(" & paramName & ".size())")
        elif isSeqOfPrimitiveNode(paramType):
          cppCallArgs.add(
            ", " & paramName & ".empty() ? nullptr : " & paramName & ".data()"
          )
          cppCallArgs.add(", static_cast<int32_t>(" & paramName & ".size())")
        elif isSeqOfObjectNode(paramType):
          let itemTypeName = seqItemTypeName(paramType)
          cppPreCall.add(
            buildCppSeqParamSetup(
              paramName, itemTypeName, lookupFfiStruct(itemTypeName)
            )
          )
          cppCallArgs.add(
            ", " & paramName & "CItems.empty() ? nullptr : " & paramName &
              "CItems.data()"
          )
          cppCallArgs.add(", static_cast<int32_t>(" & paramName & "CItems.size())")
        elif isArrayTypeNode(paramType):
          cppCallArgs.add(", " & paramName & ".data()")
        elif isCStringType(paramType):
          cppCallArgs.add(", " & paramName & ".c_str()")
        elif isEnumNode(paramType):
          # The C++ wrapper exposes `enum class <Name>` (in namespace);
          # the C ABI expects the typedef-enum `<Name>_C` at global
          # scope (codegen-suffixed to avoid namespace collision). Cast
          # at the boundary — both share int32_t underlying type so
          # the cast is a runtime no-op.
          cppCallArgs.add(", static_cast<::" & $paramType & "_C>(" & paramName & ")")
        else:
          cppCallArgs.add(", " & paramName)

    gApiCppMethodDecls.add(
      cppRetTy & " " & camelName & "(" & cppParams.join(", ") & ");"
    )

    var def =
      "inline " & cppRetTy & " " & cppCls & "::" & camelName & "(" & cppParams.join(
        ", "
      ) & ") {\n"
    def.add(cppPreCall)
    def.add("    auto c = " & funcName & "(" & cppCallArgs & ");\n")
    def.add("    if (c.error_message) {\n")
    def.add("        std::string err(c.error_message);\n")
    def.add("        " & freeFuncName & "(&c);\n")
    def.add("        return " & cppRetTy & "(std::move(err));\n")
    def.add("    }\n")
    def.add("    return " & cppRetTy & "(detail::adopt" & typeDisplayName & "(c));\n")
    def.add("}")
    gApiCppMethodDefs.add(def)

  # Step 6c: Generate Python ctypes + dataclass + methods (when -d:BrokerFfiApiGenPy)
  when defined(BrokerFfiApiGenPy):
    if not hideFromForeignSurface:
      let pySnakeName = toSnakeCase(typeDisplayName)
      let pyFreeFuncName = apiPublicCName("free_" & baseExportName & "_result")
      # Public Python dataclass uses the bare TypeName (no `Result` suffix)
      # — matches the C++ wrapper struct name and the CBOR-mode Python
      # wrapper. Method return shape is `Result[<TypeName>]`.
      let pyResultName = typeDisplayName
      let pyCResultName = typeDisplayName & "CResult"

      block:
        var pyCStruct = "class " & pyCResultName & "(ctypes.Structure):\n"
        pyCStruct.add("    _fields_ = [\n")
        pyCStruct.add("        (\"error_message\", ctypes.c_char_p),\n")
        if hasInlineFields:
          for i in 0 ..< fieldNames.len:
            let fName = $fieldNames[i]
            let fType = fieldTypes[i]
            if isSeqType(fType):
              pyCStruct.add("        (\"" & fName & "\", ctypes.c_void_p),\n")
              pyCStruct.add("        (\"" & fName & "_count\", ctypes.c_int32),\n")
            elif isArrayTypeNode(fType):
              let n = arrayNodeSize(fType)
              let elemName = arrayNodeElemName(fType)
              let ctElem = nimTypeToCtypes(ident(elemName))
              pyCStruct.add(
                "        (\"" & fName & "\", " & ctElem & " * " & $n & "),\n"
              )
            else:
              # nimTypeToCtypes now resolves enums → ctypes.c_int32
              # and distinct/alias types → underlying ctypes type
              let ctField = nimTypeToCtypes(fType)
              pyCStruct.add("        (\"" & fName & "\", " & ctField & "),\n")
        pyCStruct.add("    ]")
        gApiPyCtypesStructs.add(pyCStruct)

      block:
        var pyDc = "@dataclass\nclass " & pyResultName & ":\n"
        pyDc.add("    \"\"\"Result of " & typeDisplayName & " request.\"\"\"\n")
        if hasInlineFields:
          for i in 0 ..< fieldNames.len:
            let fName = $fieldNames[i]
            let fType = fieldTypes[i]
            let pyType = nimTypeToPyAnnotation(fType)
            let pyDefault = nimTypeToPyDefault(fType)
            pyDc.add("    " & fName & ": " & pyType & " = " & pyDefault & "\n")
        else:
          pyDc.add("    pass\n")
        gApiPyDataclasses.add(pyDc)

      block:
        if not zeroArgSig.isNil():
          let funcName = apiPublicCName(exportedFuncName(zeroArgSigName))
          let argtypesLine = "_lib." & funcName & ".argtypes = [ctypes.c_uint32]"
          let restypeLine = "_lib." & funcName & ".restype = " & pyCResultName
          gApiPyCallbackSetup.add(argtypesLine)
          gApiPyCallbackSetup.add(restypeLine)
        if not argSig.isNil():
          let funcName = apiPublicCName(exportedFuncName(argSigName))
          var argTypes = "[ctypes.c_uint32"
          for paramDef in argParams:
            for i in 0 ..< paramDef.len - 2:
              let paramType = paramDef[paramDef.len - 2]
              if isSeqOfObjectNode(paramType):
                let itemTypeName = seqItemTypeName(paramType)
                argTypes.add(
                  ", ctypes.POINTER(" & itemTypeName & "CItem), ctypes.c_int32"
                )
              elif isSeqType(paramType):
                # seq[primitive] or seq[string]: void* + count
                argTypes.add(", ctypes.c_void_p, ctypes.c_int32")
              elif isArrayTypeNode(paramType):
                # array[N, T]: pointer to first element
                let elemName = arrayNodeElemName(paramType)
                argTypes.add(
                  ", ctypes.POINTER(" & nimTypeToCtypes(ident(elemName)) & ")"
                )
              else:
                argTypes.add(", " & nimTypeToCtypes(paramType))
          argTypes.add("]")
          let argtypesLine = "_lib." & funcName & ".argtypes = " & argTypes
          let restypeLine = "_lib." & funcName & ".restype = " & pyCResultName
          gApiPyCallbackSetup.add(argtypesLine)
          gApiPyCallbackSetup.add(restypeLine)
        let freeArgtypesLine =
          "_lib." & pyFreeFuncName & ".argtypes = [ctypes.POINTER(" & pyCResultName &
          ")]"
        let freeRestypeLine = "_lib." & pyFreeFuncName & ".restype = None"
        gApiPyCallbackSetup.add(freeArgtypesLine)
        gApiPyCallbackSetup.add(freeRestypeLine)

      const I = "            "

      proc pyExtractField(fName: string, fType: NimNode): string {.compileTime.} =
        if isCStringType(fType):
          I & fName & " = c." & fName & ".decode(\"utf-8\") if c." & fName &
            " else \"\"\n"
        elif isSeqOfStringNode(fType):
          # seq[string]: char** → list[str]
          var s = I & fName & "_list: list[str] = []\n"
          s.add(I & "if c." & fName & " and c." & fName & "_count > 0:\n")
          s.add(
            I & "    _str_arr = ctypes.cast(c." & fName &
              ", ctypes.POINTER(ctypes.c_char_p))\n"
          )
          s.add(I & "    for _i in range(c." & fName & "_count):\n")
          s.add(
            I & "        " & fName &
              "_list.append(_str_arr[_i].decode(\"utf-8\") if _str_arr[_i] else \"\")\n"
          )
          s.add(I & fName & " = " & fName & "_list\n")
          s
        elif isSeqOfPrimitiveNode(fType):
          # seq[primitive]: primType* → list[int/float]
          let elemName = seqItemTypeName(fType)
          let ctElem = nimTypeToCtypes(ident(elemName))
          var s = I & fName & "_list = []\n"
          s.add(I & "if c." & fName & " and c." & fName & "_count > 0:\n")
          s.add(
            I & "    _arr = ctypes.cast(c." & fName & ", ctypes.POINTER(" & ctElem &
              "))\n"
          )
          s.add(I & "    for _i in range(c." & fName & "_count):\n")
          s.add(I & "        " & fName & "_list.append(_arr[_i])\n")
          s.add(I & fName & " = " & fName & "_list\n")
          s
        elif isSeqOfObjectNode(fType):
          # seq[CustomObject]: cast to CItem*, reconstruct dataclasses
          let itemType = seqItemTypeName(fType)
          var s = I & fName & "_list: list[" & itemType & "] = []\n"
          s.add(I & "if c." & fName & " and c." & fName & "_count > 0:\n")
          s.add(
            I & "    arr = ctypes.cast(c." & fName & ", ctypes.POINTER(" & itemType &
              "CItem))\n"
          )
          s.add(I & "    for _i in range(c." & fName & "_count):\n")
          s.add(I & "        _item = arr[_i]\n")
          let itemFields = lookupFfiStruct(itemType)
          var itemArgs: seq[string] = @[]
          for (ifName, ifType) in itemFields:
            if ifType.toLowerAscii() in ["string", "cstring"]:
              itemArgs.add(
                ifName & "=_item." & ifName & ".decode(\"utf-8\") if _item." & ifName &
                  " else \"\""
              )
            else:
              itemArgs.add(ifName & "=_item." & ifName)
          s.add(I & "        " & fName & "_list.append(" & itemType & "(\n")
          for j, arg in itemArgs:
            s.add(I & "            " & arg)
            if j < itemArgs.len - 1:
              s.add(",")
            s.add("\n")
          s.add(I & "        ))\n")
          s.add(I & fName & " = " & fName & "_list\n")
          s
        elif isArrayTypeNode(fType):
          # array[N, T]: ctypes fixed-size array → Python list
          I & fName & " = list(c." & fName & ")\n"
        elif isEnumNode(fType):
          # Enum: wrap raw int with the Python IntEnum class
          I & fName & " = " & $fType & "(c." & fName & ")\n"
        else:
          I & fName & " = c." & fName & "\n"

      proc buildPyMethodBody(
          funcName, callArgs, pyResultName2, pyFreeFuncName2: string
      ): string {.compileTime.} =
        ## Builds the body of a Python request method. Returns
        ## `Result[<TypeName>]`: success carries the decoded dataclass,
        ## error carries the C-side error_message string. Mirrors the
        ## CBOR-mode Python wrapper and the C++ wrapper Result<T>.
        result = ""
        result.add("        if self._ctx == 0:\n")
        result.add(
          "            return Result.err(\"Library context is not created\")\n"
        )
        result.add("        c = self._lib." & funcName & "(" & callArgs & ")\n")
        result.add("        try:\n")
        result.add("            if c.error_message:\n")
        result.add(
          "                return Result.err(c.error_message.decode(\"utf-8\"))\n"
        )
        if hasInlineFields:
          for i in 0 ..< fieldNames.len:
            let fName = $fieldNames[i]
            result.add(pyExtractField(fName, fieldTypes[i]))
          var dcArgs: seq[string] = @[]
          for i in 0 ..< fieldNames.len:
            let fName = $fieldNames[i]
            dcArgs.add(fName & "=" & fName)
          result.add("            return Result.ok(" & pyResultName2 & "(\n")
          for j, arg in dcArgs:
            result.add("                " & arg)
            if j < dcArgs.len - 1:
              result.add(",")
            result.add("\n")
          result.add("            ))\n")
        else:
          result.add("            return Result.ok(" & pyResultName2 & "())\n")
        result.add("        finally:\n")
        result.add("            self._lib." & pyFreeFuncName2 & "(ctypes.byref(c))")

      if not argSig.isNil():
        let funcName = apiPublicCName(exportedFuncName(argSigName))
        let pyArgMethodName =
          if hasDualSignatures:
            pySnakeName & "_" & signatureNameSuffix(argSigName)
          else:
            pySnakeName
        var pyParams = "self"
        var callArgs = "self._ctx"
        var aliasArgs: seq[string] = @[]
        var summaryParams: seq[string] = @[]
        var pyPreCall = ""
        for paramDef in argParams:
          for i in 0 ..< paramDef.len - 2:
            let paramName = $paramDef[i]
            let paramType = paramDef[paramDef.len - 2]
            let pyType = nimTypeToPyAnnotation(paramType)
            pyParams.add(", " & paramName & ": " & pyType)
            aliasArgs.add(paramName)
            summaryParams.add(paramName & ": " & pyType)
            if isSeqOfObjectNode(paramType):
              let itemTypeName = seqItemTypeName(paramType)
              pyPreCall.add(
                buildPySeqParamSetup(
                  paramName, itemTypeName, lookupFfiStruct(itemTypeName)
                )
              )
              callArgs.add(", " & paramName & "_array, len(" & paramName & "_items)")
            elif isSeqOfStringNode(paramType):
              pyPreCall.add(buildPyStringSeqParamSetup(paramName))
              callArgs.add(", " & paramName & "_ptr, len(" & paramName & ")")
            elif isSeqOfPrimitiveNode(paramType):
              let elemName = seqItemTypeName(paramType)
              let ctElem = nimTypeToCtypes(ident(elemName))
              pyPreCall.add(buildPyPrimSeqParamSetup(paramName, ctElem))
              callArgs.add(", " & paramName & "_ptr, len(" & paramName & ")")
            elif isArrayTypeNode(paramType):
              let n = arrayNodeSize(paramType)
              let elemName = arrayNodeElemName(paramType)
              let ctElem = nimTypeToCtypes(ident(elemName))
              pyPreCall.add(buildPyArrayParamSetup(paramName, ctElem, n))
              callArgs.add(", " & paramName & "_arr")
            elif isCStringType(paramType):
              callArgs.add(", " & paramName & ".encode(\"utf-8\")")
            else:
              callArgs.add(", " & paramName)

        let pyRetTy = "Result[" & pyResultName & "]"
        var pyMethod =
          "    def " & pyArgMethodName & "(" & pyParams & ") -> " & pyRetTy & ":\n"
        pyMethod.add("        \"\"\"" & typeDisplayName & " request.\"\"\"\n")
        pyMethod.add(pyPreCall)
        pyMethod.add(
          buildPyMethodBody(funcName, callArgs, pyResultName, pyFreeFuncName)
        )
        gApiPyMethods.add(pyMethod)
        gApiPyInterfaceSummary.add(
          pyArgMethodName & "(" & summaryParams.join(", ") & ") -> " & pyRetTy
        )
      if not zeroArgSig.isNil():
        let funcName = apiPublicCName(exportedFuncName(zeroArgSigName))
        let pyZeroMethodName =
          if hasDualSignatures:
            pySnakeName & "_" & signatureNameSuffix(zeroArgSigName)
          else:
            pySnakeName
        let pyRetTy = "Result[" & pyResultName & "]"
        var pyMethod = "    def " & pyZeroMethodName & "(self) -> " & pyRetTy & ":\n"
        pyMethod.add("        \"\"\"" & typeDisplayName & " request.\"\"\"\n")
        pyMethod.add(
          buildPyMethodBody(funcName, "self._ctx", pyResultName, pyFreeFuncName)
        )
        gApiPyMethods.add(pyMethod)
        gApiPyInterfaceSummary.add(pyZeroMethodName & "() -> " & pyRetTy)

  # Step 6d: Generate Rust wrapper crate entries (when -d:BrokerFfiApiGenRust)
  when defined(BrokerFfiApiGenRust):
    if not hideFromForeignSurface:
      let rsSnakeName = toSnakeCase(typeDisplayName)
      let rsFreeFuncName = apiPublicCName("free_" & baseExportName & "_result")
      let rsResultName = typeDisplayName
      let rsCResultName = typeDisplayName & "CResult"

      proc rsScalarMappable(t: NimNode): bool {.compileTime.} =
        if isCStringType(t):
          return true
        if t.kind == nnkIdent:
          let n = ($t).toLowerAscii()
          if n in [
            "bool", "int", "int8", "int16", "int32", "int64", "uint", "uint8", "byte",
            "uint16", "uint32", "uint64", "float", "float32", "float64",
          ]:
            return true
          if isEnumRegistered($t):
            return true
          if isAliasOrDistinctRegistered($t):
            return true
        false

      proc rsTypeMappable(t: NimNode): bool {.compileTime.} =
        ## Accepts the v2 native-mode set: scalars + seq[primitive] +
        ## seq[string] + seq[Object] + array[N, primitive].
        if rsScalarMappable(t):
          return true
        if isSeqType(t):
          let elem = seqItemTypeName(t)
          if isNimPrimitive(elem):
            return true
          # Object element — accept only if the object's own fields are
          # all primitive/string (parity with C++ wrapper's TCItem path).
          if isTypeRegistered(elem):
            let entry = lookupTypeEntry(elem)
            if entry.kind == atkObject:
              for f in entry.fields:
                let lc = f.nimType.toLowerAscii()
                if lc notin [
                  "bool", "int", "int8", "int16", "int32", "int64", "uint", "uint8",
                  "byte", "uint16", "uint32", "uint64", "float", "float32", "float64",
                  "string", "cstring",
                ]:
                  return false
              return true
          return false
        if isArrayTypeNode(t):
          # array[N, primitive] only — array of object would need richer
          # CItem expansion that's not in scope here.
          let elem = arrayNodeElemName(t)
          return
            isNimPrimitive(elem) and elem.toLowerAscii() notin ["string", "cstring"]
        false

      proc rsElemFfi(elemName: string): string {.compileTime.} =
        let lc = elemName.toLowerAscii()
        if lc in ["string", "cstring"]:
          return "*const ::std::os::raw::c_char"
        if isNimPrimitive(elemName):
          return nimTypeToRustFfi(ident(elemName))
        if isEnumRegistered(elemName):
          return "i32"
        if isAliasOrDistinctRegistered(elemName):
          return nimTypeToRustFfi(ident(resolveUnderlyingType(elemName)))
        elemName & "CItem"

      proc rsElemSafe(elemName: string): string {.compileTime.} =
        let lc = elemName.toLowerAscii()
        if lc in ["string", "cstring"]:
          return "String"
        nimTypeToRust(ident(elemName))

      var anyUnmappable = false
      if hasInlineFields:
        for i in 0 ..< fieldNames.len:
          if not rsTypeMappable(fieldTypes[i]):
            anyUnmappable = true
            break
      if not anyUnmappable and not argSig.isNil():
        for paramDef in argParams:
          for i in 0 ..< paramDef.len - 2:
            let pType = paramDef[paramDef.len - 2]
            if not rsTypeMappable(pType):
              anyUnmappable = true
              break
          if anyUnmappable:
            break

      if anyUnmappable:
        gApiRustMethods.add(
          "    // TODO(rust-codegen): request '" & typeDisplayName &
            "' uses a Nim type combination not yet mappable to native Rust.\n"
        )
      else:
        # ---- #[repr(C)] CResult ------------------------------------
        block:
          var ffi = "#[repr(C)]\n"
          ffi.add("#[derive(Debug)]\n")
          ffi.add("pub struct " & rsCResultName & " {\n")
          ffi.add("    pub error_message: *const ::std::os::raw::c_char,\n")
          if hasInlineFields:
            for i in 0 ..< fieldNames.len:
              let fName = $fieldNames[i]
              let fType = fieldTypes[i]
              if isSeqType(fType):
                let elem = seqItemTypeName(fType)
                ffi.add("    pub " & fName & ": *const " & rsElemFfi(elem) & ",\n")
                ffi.add("    pub " & fName & "_count: i32,\n")
              elif isArrayTypeNode(fType):
                let n = arrayNodeSize(fType)
                let elem = arrayNodeElemName(fType)
                ffi.add(
                  "    pub " & fName & ": [" & rsElemFfi(elem) & "; " & $n & "],\n"
                )
              else:
                ffi.add("    pub " & fName & ": " & nimTypeToRustFfi(fType) & ",\n")
          ffi.add("}")
          gApiRustFfiStructs.add(ffi)

        # ---- Safe Rust struct -------------------------------------
        block:
          var safe = "#[derive(Debug, Clone, Default)]\n"
          safe.add("pub struct " & rsResultName & " {\n")
          if hasInlineFields:
            for i in 0 ..< fieldNames.len:
              let fName = $fieldNames[i]
              let fType = fieldTypes[i]
              if isSeqType(fType) or isArrayTypeNode(fType):
                let elem =
                  if isSeqType(fType):
                    seqItemTypeName(fType)
                  else:
                    arrayNodeElemName(fType)
                safe.add("    pub " & fName & ": Vec<" & rsElemSafe(elem) & ">,\n")
              else:
                safe.add("    pub " & fName & ": " & nimTypeToRust(fType) & ",\n")
          else:
            safe.add("    _phantom: (),\n")
          safe.add("}")
          gApiRustStructs.add(safe)

        # ---- extern "C" function declarations ---------------------
        proc rsExtParamDecl(pName: string, pType: NimNode): string {.compileTime.} =
          if isSeqType(pType):
            let elem = seqItemTypeName(pType)
            return pName & ": *const " & rsElemFfi(elem) & ", " & pName & "_count: i32"
          if isArrayTypeNode(pType):
            let elem = arrayNodeElemName(pType)
            return pName & ": *const " & rsElemFfi(elem)
          pName & ": " & nimTypeToRustFfi(pType)

        if not zeroArgSig.isNil():
          let funcName = apiPublicCName(exportedFuncName(zeroArgSigName))
          gApiRustExternFns.add(
            "fn " & funcName & "(ctx: u32) -> " & rsCResultName & ";"
          )
        if not argSig.isNil():
          let funcName = apiPublicCName(exportedFuncName(argSigName))
          var argDecl = "ctx: u32"
          for paramDef in argParams:
            for i in 0 ..< paramDef.len - 2:
              let pName = $paramDef[i]
              let pType = paramDef[paramDef.len - 2]
              argDecl.add(", " & rsExtParamDecl(pName, pType))
          gApiRustExternFns.add(
            "fn " & funcName & "(" & argDecl & ") -> " & rsCResultName & ";"
          )
        gApiRustExternFns.add(
          "fn " & rsFreeFuncName & "(r: *mut " & rsCResultName & ");"
        )

        # ---- Pre-call setup + call args ---------------------------
        proc rsArgPreCall(pName: string, pType: NimNode): string {.compileTime.} =
          if isCStringType(pType):
            return
              "        let _" & pName & "_c = match ::std::ffi::CString::new(" & pName &
              ") { Ok(s) => s, Err(_) => return Result::err(\"invalid C string\") };\n"
          if isSeqType(pType):
            let elem = seqItemTypeName(pType)
            let lc = elem.toLowerAscii()
            if lc in ["string", "cstring"]:
              # Build Vec<CString> + Vec<*const c_char> for a seq[string] arg.
              var s =
                "        let _" & pName & "_owned: Vec<::std::ffi::CString> = " & pName &
                ".iter().map(|s| ::std::ffi::CString::new(s.as_str()).unwrap_or_default()).collect();\n"
              s.add(
                "        let _" & pName & "_ptrs: Vec<*const ::std::os::raw::c_char> = _" &
                  pName & "_owned.iter().map(|c| c.as_ptr()).collect();\n"
              )
              return s
            if isNimPrimitive(elem):
              return "" # Vec<T>.as_ptr() inline is fine.
            # seq[Object]: build per-item CString-owned columns + Vec<TCItem>.
            if isTypeRegistered(elem) and lookupTypeEntry(elem).kind == atkObject:
              let entry = lookupTypeEntry(elem)
              var s =
                "        let mut _" & pName &
                "_str_storage: Vec<::std::ffi::CString> = Vec::new();\n"
              s.add(
                "        let mut _" & pName & "_items: Vec<" & elem &
                  "CItem> = Vec::with_capacity(" & pName & ".len());\n"
              )
              s.add("        for _it in " & pName & ".iter() {\n")
              s.add("            let mut _ci = " & elem & "CItem {\n")
              for f in entry.fields:
                let lcf = f.nimType.toLowerAscii()
                if lcf in ["string", "cstring"]:
                  s.add("                " & f.name & ": ::std::ptr::null(),\n")
                else:
                  s.add("                " & f.name & ": Default::default(),\n")
              s.add("            };\n")
              for f in entry.fields:
                let lcf = f.nimType.toLowerAscii()
                if lcf in ["string", "cstring"]:
                  s.add("            {\n")
                  s.add(
                    "                let _cs = ::std::ffi::CString::new(_it." & f.name &
                      ".as_str()).unwrap_or_default();\n"
                  )
                  s.add("                _ci." & f.name & " = _cs.as_ptr();\n")
                  s.add("                _" & pName & "_str_storage.push(_cs);\n")
                  s.add("            }\n")
                else:
                  s.add("            _ci." & f.name & " = _it." & f.name & ";\n")
              s.add("            _" & pName & "_items.push(_ci);\n")
              s.add("        }\n")
              return s
            return ""
          if isArrayTypeNode(pType):
            return ""
          ""

        proc rsArgPassArgs(pName: string, pType: NimNode): string {.compileTime.} =
          if isCStringType(pType):
            return "_" & pName & "_c.as_ptr()"
          if isSeqType(pType):
            let elem = seqItemTypeName(pType)
            let lc = elem.toLowerAscii()
            if lc in ["string", "cstring"]:
              return "_" & pName & "_ptrs.as_ptr(), _" & pName & "_ptrs.len() as i32"
            if isNimPrimitive(elem):
              return pName & ".as_ptr(), " & pName & ".len() as i32"
            if isTypeRegistered(elem) and lookupTypeEntry(elem).kind == atkObject:
              return "_" & pName & "_items.as_ptr(), _" & pName & "_items.len() as i32"
            return pName
          if isArrayTypeNode(pType):
            return pName & ".as_ptr()"
          if pType.kind == nnkIdent and isEnumRegistered($pType):
            return pName & " as i32"
          if pType.kind == nnkIdent and isAliasOrDistinctRegistered($pType):
            return pName
          pName

        proc rsBuildBody(funcName, callArgs: string): string {.compileTime.} =
          result = ""
          result.add(
            "        if self.ctx == 0 { return Result::err(\"Library context is not created\"); }\n"
          )
          result.add("        unsafe {\n")
          result.add("            let mut c = " & funcName & "(" & callArgs & ");\n")
          result.add("            if !c.error_message.is_null() {\n")
          result.add(
            "                let msg = ::std::ffi::CStr::from_ptr(c.error_message).to_string_lossy().into_owned();\n"
          )
          result.add("                " & rsFreeFuncName & "(&mut c as *mut _);\n")
          result.add("                return Result::err(msg);\n")
          result.add("            }\n")
          if hasInlineFields:
            result.add("            let mut _r = " & rsResultName & "::default();\n")
            for i in 0 ..< fieldNames.len:
              let fName = $fieldNames[i]
              let fType = fieldTypes[i]
              if isCStringType(fType):
                result.add(
                  "            _r." & fName & " = if c." & fName &
                    ".is_null() { String::new() } else { ::std::ffi::CStr::from_ptr(c." &
                    fName & ").to_string_lossy().into_owned() };\n"
                )
              elif fType.kind == nnkIdent and isEnumRegistered($fType):
                result.add(
                  "            _r." & fName & " = (c." & fName & " as i32).into();\n"
                )
              elif isSeqType(fType):
                let elem = seqItemTypeName(fType)
                let lc = elem.toLowerAscii()
                if lc in ["string", "cstring"]:
                  result.add(
                    "            if !c." & fName & ".is_null() && c." & fName &
                      "_count > 0 {\n"
                  )
                  result.add(
                    "                let _slice = ::std::slice::from_raw_parts(c." &
                      fName & ", c." & fName & "_count as usize);\n"
                  )
                  result.add(
                    "                _r." & fName &
                      " = _slice.iter().map(|p| if p.is_null() { String::new() } else { ::std::ffi::CStr::from_ptr(*p).to_string_lossy().into_owned() }).collect();\n"
                  )
                  result.add("            }\n")
                elif isNimPrimitive(elem):
                  result.add(
                    "            if !c." & fName & ".is_null() && c." & fName &
                      "_count > 0 {\n"
                  )
                  result.add(
                    "                _r." & fName & " = ::std::slice::from_raw_parts(c." &
                      fName & ", c." & fName & "_count as usize).to_vec();\n"
                  )
                  result.add("            }\n")
                elif isTypeRegistered(elem) and lookupTypeEntry(elem).kind == atkObject:
                  let entry = lookupTypeEntry(elem)
                  result.add(
                    "            if !c." & fName & ".is_null() && c." & fName &
                      "_count > 0 {\n"
                  )
                  result.add(
                    "                let _slice = ::std::slice::from_raw_parts(c." &
                      fName & ", c." & fName & "_count as usize);\n"
                  )
                  result.add(
                    "                let mut _v: Vec<" & elem &
                      "> = Vec::with_capacity(_slice.len());\n"
                  )
                  result.add("                for _ci in _slice.iter() {\n")
                  result.add("                    _v.push(" & elem & " {\n")
                  for f in entry.fields:
                    let lcf = f.nimType.toLowerAscii()
                    if lcf in ["string", "cstring"]:
                      result.add(
                        "                        " & f.name & ": if _ci." & f.name &
                          ".is_null() { String::new() } else { ::std::ffi::CStr::from_ptr(_ci." &
                          f.name & ").to_string_lossy().into_owned() },\n"
                      )
                    else:
                      result.add(
                        "                        " & f.name & ": _ci." & f.name & ",\n"
                      )
                  result.add("                    });\n")
                  result.add("                }\n")
                  result.add("                _r." & fName & " = _v;\n")
                  result.add("            }\n")
              elif isArrayTypeNode(fType):
                result.add("            _r." & fName & " = c." & fName & ".to_vec();\n")
              else:
                result.add("            _r." & fName & " = c." & fName & ";\n")
            result.add("            " & rsFreeFuncName & "(&mut c as *mut _);\n")
            result.add("            Result::ok(_r)\n")
          else:
            result.add("            " & rsFreeFuncName & "(&mut c as *mut _);\n")
            result.add("            Result::ok(" & rsResultName & "::default())\n")
          result.add("        }\n")

        if not argSig.isNil():
          let funcName = apiPublicCName(exportedFuncName(argSigName))
          let rsArgMethodName =
            if hasDualSignatures:
              rsSnakeName & "_" & signatureNameSuffix(argSigName)
            else:
              rsSnakeName
          var rsParams = "&self"
          var rsCallArgs = "self.ctx"
          var rsPreCall = ""
          var rsSummaryParams: seq[string] = @[]
          for paramDef in argParams:
            for i in 0 ..< paramDef.len - 2:
              let pName = $paramDef[i]
              let pType = paramDef[paramDef.len - 2]
              let safeTy =
                if isSeqType(pType) or isArrayTypeNode(pType):
                  let elem =
                    if isSeqType(pType):
                      seqItemTypeName(pType)
                    else:
                      arrayNodeElemName(pType)
                  "Vec<" & rsElemSafe(elem) & ">"
                else:
                  nimTypeToRust(pType)
              rsParams.add(", " & pName & ": " & safeTy)
              rsPreCall.add(rsArgPreCall(pName, pType))
              rsCallArgs.add(", " & rsArgPassArgs(pName, pType))
              rsSummaryParams.add(pName & ": " & safeTy)
          var rsMethod =
            "    pub fn " & rsArgMethodName & "(" & rsParams & ") -> Result<" &
            rsResultName & "> {\n"
          rsMethod.add(rsPreCall)
          rsMethod.add(rsBuildBody(funcName, rsCallArgs))
          rsMethod.add("    }")
          gApiRustMethods.add(rsMethod)
          gApiRustInterfaceSummary.add(
            rsArgMethodName & "(" & rsSummaryParams.join(", ") & ") -> Result<" &
              rsResultName & ">"
          )
        if not zeroArgSig.isNil():
          let funcName = apiPublicCName(exportedFuncName(zeroArgSigName))
          let rsZeroMethodName =
            if hasDualSignatures:
              rsSnakeName & "_" & signatureNameSuffix(zeroArgSigName)
            else:
              rsSnakeName
          var rsMethod =
            "    pub fn " & rsZeroMethodName & "(&self) -> Result<" & rsResultName &
            "> {\n"
          rsMethod.add(rsBuildBody(funcName, "self.ctx"))
          rsMethod.add("    }")
          gApiRustMethods.add(rsMethod)
          gApiRustInterfaceSummary.add(
            rsZeroMethodName & "() -> Result<" & rsResultName & ">"
          )

  # Step 6e: Generate Go wrapper module entries (when -d:BrokerFfiApiGenGo)
  when defined(BrokerFfiApiGenGo):
    if not hideFromForeignSurface:
      let goExportedName = typeDisplayName
      let goFreeFuncName = apiPublicCName("free_" & baseExportName & "_result")
      let goResultName = typeDisplayName
      let goCResultName = "C." & typeDisplayName & "CResult"

      proc goScalarMappable(t: NimNode): bool {.compileTime.} =
        if isCStringType(t):
          return true
        if t.kind == nnkIdent:
          let n = ($t).toLowerAscii()
          if n in [
            "bool", "int", "int8", "int16", "int32", "int64", "uint", "uint8", "byte",
            "uint16", "uint32", "uint64", "float", "float32", "float64",
          ]:
            return true
          if isEnumRegistered($t):
            return true
          if isAliasOrDistinctRegistered($t):
            return true
        false

      proc goTypeMappable(t: NimNode): bool {.compileTime.} =
        if goScalarMappable(t):
          return true
        if isSeqType(t):
          let elem = seqItemTypeName(t)
          if isNimPrimitive(elem):
            return true
          if isTypeRegistered(elem):
            let entry = lookupTypeEntry(elem)
            if entry.kind == atkObject:
              for f in entry.fields:
                let lc = f.nimType.toLowerAscii()
                if lc notin [
                  "bool", "int", "int8", "int16", "int32", "int64", "uint", "uint8",
                  "byte", "uint16", "uint32", "uint64", "float", "float32", "float64",
                  "string", "cstring",
                ]:
                  return false
              return true
          return false
        if isArrayTypeNode(t):
          let elem = arrayNodeElemName(t)
          return
            isNimPrimitive(elem) and elem.toLowerAscii() notin ["string", "cstring"]
        false

      proc goExportedField(name: string): string {.compileTime.} =
        if name.len > 0 and name[0] >= 'a' and name[0] <= 'z':
          chr(ord(name[0]) - 32) & name[1 ..^ 1]
        else:
          name

      proc goCgoFieldType(t: NimNode): string {.compileTime.} =
        ## Type of the field as it appears in the cgo C struct.
        nimTypeToGoCgo(t)

      var goAnyUnmappable = false
      if hasInlineFields:
        for i in 0 ..< fieldNames.len:
          if not goTypeMappable(fieldTypes[i]):
            goAnyUnmappable = true
            break
      if not goAnyUnmappable and not argSig.isNil():
        for paramDef in argParams:
          for i in 0 ..< paramDef.len - 2:
            let pType = paramDef[paramDef.len - 2]
            if not goTypeMappable(pType):
              goAnyUnmappable = true
              break
          if goAnyUnmappable:
            break

      if goAnyUnmappable:
        gApiGoMethods.add(
          "// TODO(go-codegen): request '" & typeDisplayName &
            "' uses a Nim type combination not yet mappable to native Go."
        )
      else:
        # ---- Result struct ----------------------------------------------
        block:
          var goSafe = "type " & goResultName & " struct {\n"
          if hasInlineFields:
            for i in 0 ..< fieldNames.len:
              let fName = $fieldNames[i]
              let fType = fieldTypes[i]
              let exName = goExportedField(fName)
              if isSeqType(fType) or isArrayTypeNode(fType):
                let elem =
                  if isSeqType(fType):
                    seqItemTypeName(fType)
                  else:
                    arrayNodeElemName(fType)
                let lc = elem.toLowerAscii()
                let goElem =
                  if lc in ["string", "cstring"]:
                    "string"
                  else:
                    nimTypeToGo(ident(elem))
                goSafe.add("\t" & exName & " []" & goElem & "\n")
              else:
                goSafe.add("\t" & exName & " " & nimTypeToGo(fType) & "\n")
          else:
            goSafe.add("\t// (no fields)\n")
          goSafe.add("}")
          gApiGoStructs.add(goSafe)

        # ---- The request method (one per signature) ----------------------
        var goConvertCode = ""
        if hasInlineFields:
          for i in 0 ..< fieldNames.len:
            let fName = $fieldNames[i]
            let fType = fieldTypes[i]
            let exName = goExportedField(fName)
            if isCStringType(fType):
              goConvertCode.add(
                "\tif r." & fName & " != nil { out." & exName & " = C.GoString(r." &
                  fName & ") }\n"
              )
            elif fType.kind == nnkIdent and isEnumRegistered($fType):
              goConvertCode.add(
                "\tout." & exName & " = " & $fType & "(int32(r." & fName & "))\n"
              )
            elif fType.kind == nnkIdent and isAliasOrDistinctRegistered($fType):
              goConvertCode.add(
                "\tout." & exName & " = " & nimTypeToGo(fType) & "(r." & fName & ")\n"
              )
            elif isSeqType(fType):
              let elem = seqItemTypeName(fType)
              let lc = elem.toLowerAscii()
              if lc in ["string", "cstring"]:
                goConvertCode.add(
                  "\tif r." & fName & " != nil && r." & fName & "_count > 0 {\n"
                )
                goConvertCode.add(
                  "\t\tcs := unsafe.Slice(r." & fName & ", int(r." & fName & "_count))\n"
                )
                goConvertCode.add("\t\tout." & exName & " = make([]string, len(cs))\n")
                goConvertCode.add("\t\tfor i, p := range cs {\n")
                goConvertCode.add(
                  "\t\t\tif p != nil { out." & exName & "[i] = C.GoString(p) }\n"
                )
                goConvertCode.add("\t\t}\n")
                goConvertCode.add("\t}\n")
              elif isNimPrimitive(elem):
                goConvertCode.add(
                  "\tif r." & fName & " != nil && r." & fName & "_count > 0 {\n"
                )
                goConvertCode.add(
                  "\t\tcs := unsafe.Slice(r." & fName & ", int(r." & fName & "_count))\n"
                )
                goConvertCode.add(
                  "\t\tout." & exName & " = make([]" & nimTypeToGo(ident(elem)) &
                    ", len(cs))\n"
                )
                goConvertCode.add("\t\tfor i, v := range cs {\n")
                goConvertCode.add(
                  "\t\t\tout." & exName & "[i] = " & nimTypeToGo(ident(elem)) & "(v)\n"
                )
                goConvertCode.add("\t\t}\n")
                goConvertCode.add("\t}\n")
              elif isTypeRegistered(elem) and lookupTypeEntry(elem).kind == atkObject:
                let entry = lookupTypeEntry(elem)
                goConvertCode.add(
                  "\tif r." & fName & " != nil && r." & fName & "_count > 0 {\n"
                )
                goConvertCode.add(
                  "\t\tcs := unsafe.Slice(r." & fName & ", int(r." & fName & "_count))\n"
                )
                goConvertCode.add(
                  "\t\tout." & exName & " = make([]" & elem & ", len(cs))\n"
                )
                goConvertCode.add("\t\tfor i := range cs {\n")
                for f in entry.fields:
                  let lcf = f.nimType.toLowerAscii()
                  let efName = goExportedField(f.name)
                  if lcf in ["string", "cstring"]:
                    goConvertCode.add(
                      "\t\t\tif cs[i]." & f.name & " != nil { out." & exName & "[i]." &
                        efName & " = C.GoString(cs[i]." & f.name & ") }\n"
                    )
                  else:
                    goConvertCode.add(
                      "\t\t\tout." & exName & "[i]." & efName & " = " &
                        nimTypeToGo(ident(f.nimType)) & "(cs[i]." & f.name & ")\n"
                    )
                goConvertCode.add("\t\t}\n")
                goConvertCode.add("\t}\n")
            elif isArrayTypeNode(fType):
              let n = arrayNodeSize(fType)
              let elem = arrayNodeElemName(fType)
              goConvertCode.add(
                "\tout." & exName & " = make([]" & nimTypeToGo(ident(elem)) & ", " & $n &
                  ")\n"
              )
              goConvertCode.add("\tfor i := 0; i < " & $n & "; i++ {\n")
              goConvertCode.add(
                "\t\tout." & exName & "[i] = " & nimTypeToGo(ident(elem)) & "(r." & fName &
                  "[i])\n"
              )
              goConvertCode.add("\t}\n")
            else:
              # Plain scalar field. Convert via Go primitive type conversion.
              goConvertCode.add(
                "\tout." & exName & " = " & nimTypeToGo(fType) & "(r." & fName & ")\n"
              )

        proc goArgPreCall(pName: string, pType: NimNode): string {.compileTime.} =
          if isCStringType(pType):
            return
              "\t_c_" & pName & " := C.CString(" & pName & ")\n" &
              "\tdefer C.free(unsafe.Pointer(_c_" & pName & "))\n"
          if isSeqType(pType):
            let elem = seqItemTypeName(pType)
            let lc = elem.toLowerAscii()
            if lc in ["string", "cstring"]:
              var s = "\t_cs_" & pName & " := make([]*C.char, len(" & pName & "))\n"
              s.add("\tfor i, sv := range " & pName & " {\n")
              s.add("\t\t_cs_" & pName & "[i] = C.CString(sv)\n")
              s.add("\t}\n")
              s.add("\tdefer func() {\n")
              s.add("\t\tfor _, p := range _cs_" & pName & " {\n")
              s.add("\t\t\tC.free(unsafe.Pointer(p))\n")
              s.add("\t\t}\n")
              s.add("\t}()\n")
              s.add("\tvar _ptr_" & pName & " **C.char\n")
              s.add(
                "\tif len(_cs_" & pName & ") > 0 { _ptr_" & pName &
                  " = (**C.char)(unsafe.Pointer(&_cs_" & pName & "[0])) }\n"
              )
              return s
            if isNimPrimitive(elem):
              let cgoElem = nimTypeToGoCgo(ident(elem))
              var s = "\tvar _ptr_" & pName & " *" & cgoElem & "\n"
              s.add(
                "\tif len(" & pName & ") > 0 { _ptr_" & pName & " = (*" & cgoElem &
                  ")(unsafe.Pointer(&" & pName & "[0])) }\n"
              )
              return s
            if isTypeRegistered(elem) and lookupTypeEntry(elem).kind == atkObject:
              let entry = lookupTypeEntry(elem)
              var s =
                "\t_items_" & pName & " := make([]C." & elem & "CItem, len(" & pName &
                "))\n"
              s.add("\tvar _strs_" & pName & " []*C.char\n")
              s.add("\tfor i, _it := range " & pName & " {\n")
              for f in entry.fields:
                let lcf = f.nimType.toLowerAscii()
                let exFf = goExportedField(f.name)
                if lcf in ["string", "cstring"]:
                  s.add("\t\t{\n")
                  s.add("\t\t\t_cs := C.CString(_it." & exFf & ")\n")
                  s.add(
                    "\t\t\t_strs_" & pName & " = append(_strs_" & pName & ", _cs)\n"
                  )
                  s.add("\t\t\t_items_" & pName & "[i]." & f.name & " = _cs\n")
                  s.add("\t\t}\n")
                else:
                  s.add(
                    "\t\t_items_" & pName & "[i]." & f.name & " = " &
                      nimTypeToGoCgo(ident(f.nimType)) & "(_it." & exFf & ")\n"
                  )
              s.add("\t}\n")
              s.add("\tdefer func() {\n")
              s.add("\t\tfor _, p := range _strs_" & pName & " {\n")
              s.add("\t\t\tC.free(unsafe.Pointer(p))\n")
              s.add("\t\t}\n")
              s.add("\t}()\n")
              s.add("\tvar _ptr_" & pName & " *C." & elem & "CItem\n")
              s.add(
                "\tif len(_items_" & pName & ") > 0 { _ptr_" & pName & " = (*C." & elem &
                  "CItem)(unsafe.Pointer(&_items_" & pName & "[0])) }\n"
              )
              return s
            return ""
          ""

        proc goArgPassArgs(pName: string, pType: NimNode): string {.compileTime.} =
          if isCStringType(pType):
            return "_c_" & pName
          if isSeqType(pType):
            let elem = seqItemTypeName(pType)
            let lc = elem.toLowerAscii()
            if lc in ["string", "cstring"]:
              return "_ptr_" & pName & ", C.int32_t(len(_cs_" & pName & "))"
            if isNimPrimitive(elem):
              return "_ptr_" & pName & ", C.int32_t(len(" & pName & "))"
            if isTypeRegistered(elem) and lookupTypeEntry(elem).kind == atkObject:
              return "_ptr_" & pName & ", C.int32_t(len(_items_" & pName & "))"
            return pName
          if isArrayTypeNode(pType):
            return
              "(*" & nimTypeToGoCgo(ident(arrayNodeElemName(pType))) &
              ")(unsafe.Pointer(&" & pName & "[0]))"
          if pType.kind == nnkIdent and isEnumRegistered($pType):
            return "C." & $pType & "_C(" & pName & ")"
          if pType.kind == nnkIdent and isAliasOrDistinctRegistered($pType):
            return nimTypeToGoCgo(pType) & "(" & pName & ")"
          if isCStringType(pType):
            return "_c_" & pName
          # Plain scalar
          nimTypeToGoCgo(pType) & "(" & pName & ")"

        proc goBuildBody(funcName, callArgs: string): string {.compileTime.} =
          result = ""
          result.add(
            "\tif l.ctx == 0 { return " & goResultName &
              "{}, errors.New(\"library context is not created\") }\n"
          )
          result.add("\tr := C." & funcName & "(" & callArgs & ")\n")
          result.add("\tif r.error_message != nil {\n")
          result.add("\t\tmsg := C.GoString(r.error_message)\n")
          result.add("\t\tC." & goFreeFuncName & "(&r)\n")
          result.add("\t\treturn " & goResultName & "{}, errors.New(msg)\n")
          result.add("\t}\n")
          result.add("\tvar out " & goResultName & "\n")
          result.add(goConvertCode)
          result.add("\tC." & goFreeFuncName & "(&r)\n")
          result.add("\treturn out, nil\n")

        if not argSig.isNil():
          let funcName = apiPublicCName(exportedFuncName(argSigName))
          let goArgMethodName =
            if hasDualSignatures:
              goExportedName & signaturePascalSuffix(argSigName)
            else:
              goExportedName
          var goParams = "l *__LIB_OWNER_CLASS__"
          var goCallArgs = "l.ctx"
          var goPreCall = ""
          var goSummaryParams: seq[string] = @[]
          for paramDef in argParams:
            for i in 0 ..< paramDef.len - 2:
              let pName = $paramDef[i]
              let pType = paramDef[paramDef.len - 2]
              let safeTy =
                if isSeqType(pType) or isArrayTypeNode(pType):
                  let elem =
                    if isSeqType(pType):
                      seqItemTypeName(pType)
                    else:
                      arrayNodeElemName(pType)
                  let lc = elem.toLowerAscii()
                  if lc in ["string", "cstring"]:
                    "[]string"
                  else:
                    "[]" & nimTypeToGo(ident(elem))
                else:
                  nimTypeToGo(pType)
              goParams.add(", " & pName & " " & safeTy)
              goPreCall.add(goArgPreCall(pName, pType))
              goCallArgs.add(", " & goArgPassArgs(pName, pType))
              goSummaryParams.add(pName & " " & safeTy)
          var goMethod =
            "func (" & goParams & ") " & goArgMethodName & "(" & ") (" & goResultName &
            ", error) {\n"
          # Reformat to avoid empty paren after method name: rebuild.
          goMethod = "func (l *__LIB_OWNER_CLASS__) " & goArgMethodName & "("
          var firstParam = true
          for paramDef in argParams:
            for i in 0 ..< paramDef.len - 2:
              let pName = $paramDef[i]
              let pType = paramDef[paramDef.len - 2]
              let safeTy =
                if isSeqType(pType) or isArrayTypeNode(pType):
                  let elem =
                    if isSeqType(pType):
                      seqItemTypeName(pType)
                    else:
                      arrayNodeElemName(pType)
                  let lc = elem.toLowerAscii()
                  if lc in ["string", "cstring"]:
                    "[]string"
                  else:
                    "[]" & nimTypeToGo(ident(elem))
                else:
                  nimTypeToGo(pType)
              if not firstParam:
                goMethod.add(", ")
              goMethod.add(pName & " " & safeTy)
              firstParam = false
          goMethod.add(") (" & goResultName & ", error) {\n")
          goMethod.add(goPreCall)
          goMethod.add(goBuildBody(funcName, goCallArgs))
          goMethod.add("}")
          gApiGoMethods.add(goMethod)
          gApiGoInterfaceSummary.add(
            goArgMethodName & "(" & goSummaryParams.join(", ") & ") (" & goResultName &
              ", error)"
          )
        if not zeroArgSig.isNil():
          let funcName = apiPublicCName(exportedFuncName(zeroArgSigName))
          let goZeroMethodName =
            if hasDualSignatures:
              goExportedName & signaturePascalSuffix(zeroArgSigName)
            else:
              goExportedName
          var goMethod =
            "func (l *__LIB_OWNER_CLASS__) " & goZeroMethodName & "() (" & goResultName &
            ", error) {\n"
          goMethod.add(goBuildBody(funcName, "l.ctx"))
          goMethod.add("}")
          gApiGoMethods.add(goMethod)
          gApiGoInterfaceSummary.add(
            goZeroMethodName & "() (" & goResultName & ", error)"
          )

  # Step 7: Append free_result header declaration
  if not hideFromForeignSurface:
    appendHeaderDecl(freeHeaderProto)

  when defined(brokerDebug):
    echo result.repr

{.pop.}
macro generateApiRequestBrokerDeferred*(body: untyped): untyped =
  ## Deferred codegen macro. By the time this expands, any preceding
  ## `autoRegisterApiType` calls have already populated the type registry,
  ## so `lookupFfiStruct` will find external types.
  generateApiRequestBrokerImpl(body)

{.push raises: [].}

proc generateApiRequestBroker*(body: NimNode): NimNode =
  ## Two-phase API request broker generation:
  ## 1. Emit `autoRegisterApiType` calls for external types (typed macro phase)
  ##    and `registerArraySizeConst` calls for array-size const idents
  ## 2. Emit deferred codegen macro that runs AFTER registrations complete
  result = newStmtList()

  # Phase 1a: auto-register external types (these typed macros run first)
  let externalIdents = discoverExternalTypes(body)
  if externalIdents.len > 0:
    result.add(emitAutoRegistrations(externalIdents))

  # Phase 1b: pre-resolve const idents used as array sizes
  let sizeIdents = discoverArraySizeIdents(body)
  if sizeIdents.len > 0:
    result.add(emitArraySizeRegistrations(sizeIdents))

  # Phase 2: deferred codegen (runs after registrations complete)
  result.add(newCall(ident("generateApiRequestBrokerDeferred"), copyNimTree(body)))

{.pop.}
