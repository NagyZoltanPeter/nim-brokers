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
import ./helper/broker_utils, ./broker_context, ./mt_request_broker, ./api_common

export results, chronos, chronicles, broker_context, mt_request_broker, api_common

# ---------------------------------------------------------------------------
# Macro code generator
# ---------------------------------------------------------------------------

proc generateApiRequestBroker*(body: NimNode): NimNode {.raises: [ValueError].} =
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

  # Step 2: Generate all MT broker code
  result = newStmtList()
  result.add(generateMtRequestBroker(body))

  # Step 2b: Generate per-type provider cleanup proc and register it for
  # registerBrokerLibrary shutdown.
  let cleanupProcName = "cleanupApiRequestProvider_" & typeDisplayName
  let cleanupProcIdent = ident(cleanupProcName)
  let cleanupCtxIdent = genSym(nskParam, "ctx")
  result.add(
    quote do:
      proc `cleanupProcIdent`(`cleanupCtxIdent`: BrokerContext) =
        `typeIdent`.clearProvider(`cleanupCtxIdent`)

  )
  gApiRequestCleanupProcNames.add(cleanupProcName)

  # Step 3: Generate C result struct type
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
  # seq[T] fields expand to two C fields: pointer + count
  if hasInlineFields:
    for i in 0 ..< fieldNames.len:
      if isSeqType(fieldTypes[i]):
        # seq[T] → pointer field + int32 count field
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
      else:
        let cFieldType = toCFieldType(fieldTypes[i])
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

  # Step 4: Generate encode proc (Nim object → C result struct)
  let encodeProcIdent = ident("encode" & typeDisplayName & "ToC")
  let objIdent = ident("obj")
  var hasSeqFields = false
  if hasInlineFields:
    var encodeBody = newStmtList()
    for i in 0 ..< fieldNames.len:
      let fName = fieldNames[i]
      let fType = fieldTypes[i]
      if isSeqType(fType):
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
      elif isCStringType(fType):
        encodeBody.add(
          quote do:
            result.`fName` = allocCStringCopy(`objIdent`.`fName`)
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

  # Step 4b: Generate free_result function
  # Frees all allocated memory in a C result struct (strings, arrays, etc.)
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
        if isSeqType(fType):
          let itemTypeName = seqItemTypeName(fType)
          let itemFields = lookupFfiStruct(itemTypeName)
          let countFieldIdent = ident($fName & "_count")
          let arrIdent = genSym(nskLet, "arr")
          let cItemIdent = ident(itemTypeName & "CItem")
          let jIdent = genSym(nskForVar, "j")

          # Free string fields inside each array element, then the array
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

  # Step 5: Generate C-exported request functions

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
          let brokerCtx = BrokerContext(ctx)
          let res = waitFor `typeIdent`.request(brokerCtx)
          if res.isOk():
            return `encodeProcIdent`(res.get())
          else:
            var errResult: `cResultIdent`
            errResult.error_message = allocCStringCopy(res.error())
            return errResult

    )

    # Append header declarations
    var headerFields: seq[(string, string)] = @[]
    headerFields.add(("error_message", "char*"))
    if hasInlineFields:
      for i in 0 ..< fieldNames.len:
        if isSeqType(fieldTypes[i]):
          let itemTypeName = seqItemTypeName(fieldTypes[i])
          headerFields.add(($fieldNames[i], itemTypeName & "CItem*"))
          headerFields.add(($fieldNames[i] & "_count", "int32_t"))
        else:
          headerFields.add(($fieldNames[i], nimTypeToCOutput(fieldTypes[i])))
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
        if isSeqType(paramType):
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
        else:
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
          else:
            nimCallArgs.add(cParamIdent)

          headerParams.add((paramNameStr, nimTypeToCInput(paramType)))
          wrapperParams.add((paramNameStr, $cParamType))

    # Build the request call with decoded args
    let brokerCtxIdent = ident("brokerCtx")
    var requestCall = newCall(ident("request"), copyNimTree(typeIdent), brokerCtxIdent)
    for arg in nimCallArgs:
      requestCall.add(arg)

    var funcBody = newStmtList()
    funcBody.add(
      quote do:
        let `brokerCtxIdent` = BrokerContext(ctx)
    )
    funcBody.add(decodeStmts)
    funcBody.add(
      quote do:
        let res = waitFor `requestCall`
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
      var headerFields: seq[(string, string)] = @[]
      headerFields.add(("error_message", "char*"))
      if hasInlineFields:
        for i in 0 ..< fieldNames.len:
          if isSeqType(fieldTypes[i]):
            let itemTypeName = seqItemTypeName(fieldTypes[i])
            headerFields.add(($fieldNames[i], itemTypeName & "CItem*"))
            headerFields.add(($fieldNames[i] & "_count", "int32_t"))
          else:
            headerFields.add(($fieldNames[i], nimTypeToCOutput(fieldTypes[i])))
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

  # Step 6: Generate C++ result struct + modern class methods
  let freeFuncName = apiPublicCName("free_" & baseExportName & "_result")

  # Use placeholder for namespace — resolved during header generation
  let cppNs = "__CPP_NS__"

  # Convert PascalCase type name to camelCase for method name
  var camelName = typeDisplayName
  if camelName.len > 0:
    camelName[0] = chr(ord(camelName[0]) + 32 * ord(camelName[0] in {'A' .. 'Z'}))

  # 6a: Generate C++ result struct with RAII constructor from C struct
  block:
    if hideFromForeignSurface:
      discard
    else:
      let cppResultName = typeDisplayName & "Result"
      var cppStruct = "struct " & cppResultName & " {\n"
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
      cppStruct.add("    " & cppResultName & "() = default;\n")
      let cResultName = typeDisplayName & "CResult"
      cppStruct.add("    explicit " & cppResultName & "(" & cResultName & "& c)")
      if hasInlineFields:
        var ctorInits: seq[string] = @[]
        for i in 0 ..< fieldNames.len:
          let fName = $fieldNames[i]
          let fType = fieldTypes[i]
          if isCStringType(fType):
            ctorInits.add(fName & "(c." & fName & " ? c." & fName & " : \"\")")
          elif isSeqType(fType):
            discard
          else:
            ctorInits.add(fName & "(c." & fName & ")")
        if ctorInits.len > 0:
          cppStruct.add("\n        : " & ctorInits.join("\n        , "))
      cppStruct.add(" {\n")
      if hasInlineFields:
        for i in 0 ..< fieldNames.len:
          let fName = $fieldNames[i]
          let fType = fieldTypes[i]
          if isSeqType(fType):
            let itemTypeName = seqItemTypeName(fType)
            let countField = fName & "_count"
            cppStruct.add(
              "        if (c." & fName & " && c." & countField & " > 0) {\n"
            )
            cppStruct.add(
              "            auto* arr = static_cast<" & itemTypeName & "CItem*>(c." &
                fName & ");\n"
            )
            cppStruct.add("            " & fName & ".reserve(c." & countField & ");\n")
            cppStruct.add(
              "            for (int32_t i = 0; i < c." & countField & "; ++i)\n"
            )
            cppStruct.add("                " & fName & ".emplace_back(arr[i]);\n")
            cppStruct.add("        }\n")
      cppStruct.add("        " & freeFuncName & "(&c);\n")
      cppStruct.add("    }\n")
      cppStruct.add("};\n")
      gApiCppStructs.add(cppStruct)

  # 6b: Generate modern C++ class methods returning Result<CppStruct>
  let cppResultType = cppNs & "::Result<" & cppNs & "::" & typeDisplayName & "Result>"

  if not hideFromForeignSurface and not zeroArgSig.isNil():
    let funcName = apiPublicCName(exportedFuncName(zeroArgSigName))
    var cppMethod = "inline " & cppResultType & " " & camelName & "() {\n"
    cppMethod.add("        auto c = " & funcName & "(ctx_);\n")
    cppMethod.add("        if (c.error_message) {\n")
    cppMethod.add("            std::string err(c.error_message);\n")
    cppMethod.add("            " & freeFuncName & "(&c);\n")
    cppMethod.add("            return " & cppResultType & "(std::move(err));\n")
    cppMethod.add("        }\n")
    cppMethod.add(
      "        return " & cppResultType & "(" & cppNs & "::" & typeDisplayName &
        "Result(c));\n"
    )
    cppMethod.add("    }")
    gApiCppClassMethods.add(cppMethod)

  if not hideFromForeignSurface and not argSig.isNil():
    let funcName = apiPublicCName(exportedFuncName(argSigName))
    # Build C++ method params and C call args
    var cppParams: seq[string] = @[]
    var cppCallArgs = "ctx_"
    var cppPreCall = ""
    for paramDef in argParams:
      for i in 0 ..< paramDef.len - 2:
        let paramName = $paramDef[i]
        let paramType = paramDef[paramDef.len - 2]
        let cppParamType =
          if isSeqType(paramType):
            "const std::vector<" & cppNs & "::" & seqItemTypeName(paramType) & ">&"
          else:
            nimTypeToCppParam(paramType)
        cppParams.add(cppParamType & " " & paramName)
        if isSeqType(paramType):
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
        elif isCStringType(paramType):
          cppCallArgs.add(", " & paramName & ".c_str()")
        else:
          cppCallArgs.add(", " & paramName)
    var cppMethod =
      "inline " & cppResultType & " " & camelName & "(" & cppParams.join(", ") & ") {\n"
    cppMethod.add(cppPreCall)
    cppMethod.add("        auto c = " & funcName & "(" & cppCallArgs & ");\n")
    cppMethod.add("        if (c.error_message) {\n")
    cppMethod.add("            std::string err(c.error_message);\n")
    cppMethod.add("            " & freeFuncName & "(&c);\n")
    cppMethod.add("            return " & cppResultType & "(std::move(err));\n")
    cppMethod.add("        }\n")
    cppMethod.add(
      "        return " & cppResultType & "(" & cppNs & "::" & typeDisplayName &
        "Result(c));\n"
    )
    cppMethod.add("    }")
    gApiCppClassMethods.add(cppMethod)

  # Step 6c: Generate Python ctypes + dataclass + methods (when -d:BrokerFfiApiGenPy)
  when defined(BrokerFfiApiGenPy):
    if not hideFromForeignSurface:
      let pySnakeName = toSnakeCase(typeDisplayName)
      let pyFreeFuncName = apiPublicCName("free_" & baseExportName & "_result")
      let pyResultName = typeDisplayName & "Result"
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
            else:
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
              if isSeqType(paramType):
                let itemTypeName = seqItemTypeName(paramType)
                argTypes.add(
                  ", ctypes.POINTER(" & itemTypeName & "CItem), ctypes.c_int32"
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
        elif isSeqType(fType):
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
        else:
          I & fName & " = c." & fName & "\n"

      proc buildPyMethodBody(
          funcName, callArgs, pyResultName2, pyFreeFuncName2: string
      ): string {.compileTime.} =
        result = ""
        result.add("        c = self._lib." & funcName & "(" & callArgs & ")\n")
        result.add("        try:\n")
        result.add("            if c.error_message:\n")
        result.add(
          "                raise __LIB_ERROR__(c.error_message.decode(\"utf-8\"))\n"
        )
        if hasInlineFields:
          for i in 0 ..< fieldNames.len:
            let fName = $fieldNames[i]
            result.add(pyExtractField(fName, fieldTypes[i]))
          var dcArgs: seq[string] = @[]
          for i in 0 ..< fieldNames.len:
            let fName = $fieldNames[i]
            dcArgs.add(fName & "=" & fName)
          result.add("            return " & pyResultName2 & "(\n")
          for j, arg in dcArgs:
            result.add("                " & arg)
            if j < dcArgs.len - 1:
              result.add(",")
            result.add("\n")
          result.add("            )\n")
        else:
          result.add("            return " & pyResultName2 & "()\n")
        result.add("        finally:\n")
        result.add("            self._lib." & pyFreeFuncName2 & "(ctypes.byref(c))")

      if not argSig.isNil():
        let funcName = apiPublicCName(exportedFuncName(argSigName))
        var pyParams = "self"
        var callArgs = "self._ctx"
        var aliasArgs: seq[string] = @[]
        var pyPreCall = ""
        for paramDef in argParams:
          for i in 0 ..< paramDef.len - 2:
            let paramName = $paramDef[i]
            let paramType = paramDef[paramDef.len - 2]
            let pyType = nimTypeToPyAnnotation(paramType)
            pyParams.add(", " & paramName & ": " & pyType)
            aliasArgs.add(paramName)
            if isSeqType(paramType):
              let itemTypeName = seqItemTypeName(paramType)
              pyPreCall.add(
                buildPySeqParamSetup(
                  paramName, itemTypeName, lookupFfiStruct(itemTypeName)
                )
              )
              callArgs.add(", " & paramName & "_array, len(" & paramName & "_items)")
            elif isCStringType(paramType):
              callArgs.add(", " & paramName & ".encode(\"utf-8\")")
            else:
              callArgs.add(", " & paramName)

        var pyMethod =
          "    def " & camelName & "(" & pyParams & ") -> " & pyResultName & ":\n"
        pyMethod.add("        \"\"\"" & typeDisplayName & " request.\"\"\"\n")
        pyMethod.add("        self._requireContext()\n")
        pyMethod.add(pyPreCall)
        pyMethod.add(
          buildPyMethodBody(funcName, callArgs, pyResultName, pyFreeFuncName)
        )
        pyMethod.add("\n\n")
        pyMethod.add(
          "    def " & pySnakeName & "(" & pyParams & ") -> " & pyResultName & ":\n"
        )
        pyMethod.add(
          "        return self." & camelName & "(" & aliasArgs.join(", ") & ")"
        )
        gApiPyMethods.add(pyMethod)
      elif not zeroArgSig.isNil():
        let funcName = apiPublicCName(exportedFuncName(zeroArgSigName))
        var pyMethod = "    def " & camelName & "(self) -> " & pyResultName & ":\n"
        pyMethod.add("        \"\"\"" & typeDisplayName & " request.\"\"\"\n")
        pyMethod.add("        self._requireContext()\n")
        pyMethod.add(
          buildPyMethodBody(funcName, "self._ctx", pyResultName, pyFreeFuncName)
        )
        pyMethod.add("\n\n")
        pyMethod.add("    def " & pySnakeName & "(self) -> " & pyResultName & ":\n")
        pyMethod.add("        return self." & camelName & "()")
        gApiPyMethods.add(pyMethod)

  # Step 7: Append free_result header declaration (C side still needs it)
  if not hideFromForeignSurface:
    appendHeaderDecl(freeHeaderProto)

  when defined(brokerDebug):
    echo result.repr

{.pop.}
