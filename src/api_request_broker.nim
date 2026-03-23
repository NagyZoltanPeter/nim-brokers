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

proc generateApiRequestBroker*(body: NimNode): NimNode =
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

  # Parse signatures (mirroring mt_request_broker logic)
  var zeroArgSig: NimNode = nil
  var argSig: NimNode = nil
  var argParams: seq[NimNode] = @[]

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
      elif paramCount >= 1:
        argSig = stmt
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

  # Step 2: Generate all MT broker code
  result = newStmtList()
  result.add(generateMtRequestBroker(body))

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
              let `arrIdent` = cast[ptr UncheckedArray[`cItemIdent`]](alloc(
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
    let freeProcName = "free_" & snakeName & "_result"
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
                dealloc(`rIdent`.`fName`)
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
    let freeProcName2 = "free_" & snakeName & "_result"
    freeHeaderProto =
      generateCFuncProto(freeProcName2, "void", @[("r", typeDisplayName & "CResult*")])
    cppFreeMethod =
      "void free" & typeDisplayName & "Result(" & typeDisplayName & "CResult* r) { " &
      freeProcName2 & "(r); }"

  # Step 5: Generate C-exported request functions

  # Zero-arg signature
  if not zeroArgSig.isNil():
    let funcName = snakeName & "_request"
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
    appendHeaderDecl(structDecl)

    let funcProto =
      generateCFuncProto(funcName, typeDisplayName & "CResult", @[("ctx", "uint32_t")])
    appendHeaderDecl(funcProto)

  # Arg-based signature
  if not argSig.isNil():
    let funcName = snakeName & "_request_with_args"
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

    for paramDef in argParams:
      for i in 0 ..< paramDef.len - 2:
        let paramName = paramDef[i]
        let paramType = paramDef[paramDef.len - 2]
        let cParamType = toCFieldType(paramType)
        let cParamIdent = ident("c_" & $paramName)

        cFormalParams.add(
          newTree(nnkIdentDefs, cParamIdent, cParamType, newEmptyNode())
        )

        # Decode C param to Nim type
        if isCStringType(paramType):
          let nimParamIdent = ident("nim_" & $paramName)
          decodeStmts.add(
            quote do:
              let `nimParamIdent` = $`cParamIdent`
          )
          nimCallArgs.add(nimParamIdent)
        else:
          nimCallArgs.add(cParamIdent)

        headerParams.add(($paramName, nimTypeToCInput(paramType)))

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
      appendHeaderDecl(structDecl)

    let funcProto =
      generateCFuncProto(funcName, typeDisplayName & "CResult", headerParams)
    appendHeaderDecl(funcProto)

  # Step 6: Generate C++ result struct + modern class methods
  let freeFuncName = "free_" & snakeName & "_result"

  # Use placeholder for namespace — resolved during header generation
  let cppNs = "__CPP_NS__"

  # Convert PascalCase type name to camelCase for method name
  var camelName = typeDisplayName
  if camelName.len > 0:
    camelName[0] = chr(ord(camelName[0]) + 32 * ord(camelName[0] in {'A' .. 'Z'}))

  # 6a: Generate C++ result struct with RAII constructor from C struct
  block:
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
        elif cppType in ["int8_t", "int16_t", "int32_t", "int64_t",
                          "uint8_t", "uint16_t", "uint32_t", "uint64_t",
                          "float", "double"]:
          cppStruct.add(" = 0")
        cppStruct.add(";\n")
    cppStruct.add("    " & cppResultName & "() = default;\n")
    # Constructor from C result — copies data then frees the C struct
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
          discard # handled in body
        else:
          ctorInits.add(fName & "(c." & fName & ")")
      if ctorInits.len > 0:
        cppStruct.add("\n        : " & ctorInits.join("\n        , "))
    cppStruct.add(" {\n")
    # Handle seq[T] fields in the constructor body
    if hasInlineFields:
      for i in 0 ..< fieldNames.len:
        let fName = $fieldNames[i]
        let fType = fieldTypes[i]
        if isSeqType(fType):
          let itemTypeName = seqItemTypeName(fType)
          let countField = fName & "_count"
          cppStruct.add("        if (c." & fName & " && c." & countField & " > 0) {\n")
          cppStruct.add("            auto* arr = static_cast<" & itemTypeName & "CItem*>(c." & fName & ");\n")
          cppStruct.add("            " & fName & ".reserve(c." & countField & ");\n")
          cppStruct.add("            for (int32_t i = 0; i < c." & countField & "; ++i)\n")
          cppStruct.add("                " & fName & ".emplace_back(arr[i]);\n")
          cppStruct.add("        }\n")
    cppStruct.add("        " & freeFuncName & "(&c);\n")
    cppStruct.add("    }\n")
    cppStruct.add("};\n")
    gApiCppStructs.add(cppStruct)

  # 6b: Generate modern C++ class methods returning Result<CppStruct>
  let cppResultType = cppNs & "::Result<" & cppNs & "::" & typeDisplayName & "Result>"

  if not zeroArgSig.isNil():
    let funcName = snakeName & "_request"
    var cppMethod = "inline " & cppResultType & " " & camelName & "() {\n"
    cppMethod.add("        auto c = " & funcName & "(ctx_);\n")
    cppMethod.add("        if (c.error_message) {\n")
    cppMethod.add("            std::string err(c.error_message);\n")
    cppMethod.add("            " & freeFuncName & "(&c);\n")
    cppMethod.add("            return " & cppResultType & "(std::move(err));\n")
    cppMethod.add("        }\n")
    cppMethod.add("        return " & cppResultType & "(" & cppNs & "::" & typeDisplayName & "Result(c));\n")
    cppMethod.add("    }")
    gApiCppClassMethods.add(cppMethod)

  if not argSig.isNil():
    let funcName = snakeName & "_request_with_args"
    # Build C++ method params and C call args
    var cppParams: seq[string] = @[]
    var cppCallArgs = "ctx_"
    for paramDef in argParams:
      for i in 0 ..< paramDef.len - 2:
        let paramName = $paramDef[i]
        let paramType = paramDef[paramDef.len - 2]
        let cppParamType = nimTypeToCppParam(paramType)
        cppParams.add(cppParamType & " " & paramName)
        if isCStringType(paramType):
          cppCallArgs.add(", " & paramName & ".c_str()")
        else:
          cppCallArgs.add(", " & paramName)
    var cppMethod = "inline " & cppResultType & " " & camelName & "(" & cppParams.join(", ") & ") {\n"
    cppMethod.add("        auto c = " & funcName & "(" & cppCallArgs & ");\n")
    cppMethod.add("        if (c.error_message) {\n")
    cppMethod.add("            std::string err(c.error_message);\n")
    cppMethod.add("            " & freeFuncName & "(&c);\n")
    cppMethod.add("            return " & cppResultType & "(std::move(err));\n")
    cppMethod.add("        }\n")
    cppMethod.add("        return " & cppResultType & "(" & cppNs & "::" & typeDisplayName & "Result(c));\n")
    cppMethod.add("    }")
    gApiCppClassMethods.add(cppMethod)

  # Step 7: Append free_result header declaration (C side still needs it)
  appendHeaderDecl(freeHeaderProto)

  when defined(brokerDebug):
    echo result.repr

{.pop.}
