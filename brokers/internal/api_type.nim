## ApiType
## -------
## Declares a struct type that can be used as an element type in `seq[T]`
## fields of `RequestBroker(API)` result types.
##
## When compiled with `-d:BrokerFfiApi`, `ApiType` generates:
## 1. The normal Nim type definition (usable from Nim code)
## 2. A `{.exportc.}` C-compatible item struct (`<TypeName>CItem`) using the
##    platform's normal C ABI layout
## 3. An encode proc (`encode<TypeName>ToCItem`) that converts Nim → CItem
## 4. A C header struct declaration appended to the compile-time accumulator
## 5. Registration in the compile-time FFI struct registry
##
## Usage:
## ```nim
## ApiType:
##   type DeviceInfo = object
##     deviceId*: int64
##     name*: string
##     online*: bool
## ```
##
## Then use in a RequestBroker result:
## ```nim
## RequestBroker(API):
##   type ListDevices = object
##     devices*: seq[DeviceInfo]
##   proc signature*(): Future[Result[ListDevices, string]] {.async.}
## ```

{.push raises: [].}

import std/[macros, strutils]
import ./helper/broker_utils, ./api_common

export api_common

proc typeNodeOf*(ftype: string): NimNode {.compileTime.} =
  ## Convert a stringified field type (e.g. `"int32"`, `"seq[byte]"`,
  ## `"array[4, int32]"`, `"Tag"`) back into a structured AST node that
  ## downstream type mappers (`toCFieldType`, `nimTypeToCpp`,
  ## `nimTypeToPyAnnotation`, etc.) can pattern-match on. A simple
  ## identifier round-trips via `ident()`; anything containing brackets
  ## goes through `parseExpr` so we get a proper `nnkBracketExpr` rather
  ## than a malformed single-ident node.
  let trimmed = ftype.strip()
  if '[' in trimmed:
    try:
      return parseExpr(trimmed)
    except ValueError as e:
      error("could not parse FFI field type '" & trimmed & "': " & e.msg)
    except CatchableError as e:
      error("could not parse FFI field type '" & trimmed & "': " & e.msg)
  ident(trimmed)

proc generateApiType*(
    body: NimNode, emitTypeDefinition = true
): NimNode {.compileTime.} =
  ## Generate CItem type, encode proc, and C/C++/Python codegen for a type.
  ##
  ## When `emitTypeDefinition` is true (default, used by `ApiType` macro),
  ## the original Nim type definition is re-emitted with exported fields.
  ## When false (used by auto-resolution), the type is already defined
  ## externally and only the CItem/encode/language codegen is generated.
  let parsed = parseSingleTypeDef(body, "ApiType", collectFieldInfo = true)
  let typeName = sanitizeIdentName(parsed.typeIdent)
  let typeIdent = parsed.typeIdent

  if not parsed.hasInlineFields:
    error("ApiType requires an inline object definition with fields", body)

  # Register fields in compile-time accumulator. Use `repr` rather than `$`
  # because `$` on a NimNode panics for `nnkBracketExpr` (e.g. `seq[byte]`,
  # `array[4, int32]`) when the inner idents have not been symbol-bound —
  # which is the case for synthetic bodies built by api_type_resolver from
  # external types.
  proc nodeToTypeStr(n: NimNode): string =
    if n.kind == nnkSym or n.kind == nnkIdent:
      $n
    else:
      n.repr.strip()

  var fields: seq[(string, string)] = @[]
  for i in 0 ..< parsed.fieldNames.len:
    fields.add(
      (nodeToTypeStr(parsed.fieldNames[i]), nodeToTypeStr(parsed.fieldTypes[i]))
    )
  registerApiFfiStruct(typeName, fields)

  result = newStmtList()

  # CItem + encode proc + native struct emission are native-ABI only. CBOR
  # mode reads the schema directly via `gApiTypeRegistry`, so we can skip
  # all of the native-only codegen below — and that's required for inner
  # objects whose fields contain `seq[T]` / distinct-over-seq, since the
  # CItem layout has no count companion to pair with each `pointer` field.
  when brokerFfiMode == mfCbor:
    return result

  # 1. Emit normal Nim type definition (copy original body) — skipped for
  #    auto-resolved external types where the type is already defined.
  if emitTypeDefinition:
    for stmt in body:
      if stmt.kind == nnkTypeSection:
        # Re-export fields (add * to field names)
        var clonedSect = copyNimTree(stmt)
        for typeDef in clonedSect:
          if typeDef.kind == nnkTypeDef:
            # Export the type name
            typeDef[0] = postfix(baseTypeIdent(typeDef[0]), "*")
            # Export fields
            let rhs = typeDef[2]
            if rhs.kind == nnkObjectTy:
              let recList = rhs[2]
              if recList.kind == nnkRecList:
                for field in recList:
                  if field.kind == nnkIdentDefs:
                    for i in 0 ..< field.len - 2:
                      field[i] = exportIdentNode(field[i])
        result.add(clonedSect)

  # 2. Emit CItem Nim type ({.exportc.}, default C ABI layout)
  let cItemIdent = ident(typeName & "CItem")
  let exportedCItemIdent = postfix(copyNimTree(cItemIdent), "*")

  var cItemFields = newTree(nnkRecList)
  for (fname, ftype) in fields:
    let cFieldType = toCFieldType(typeNodeOf(ftype))
    cItemFields.add(
      newTree(nnkIdentDefs, postfix(ident(fname), "*"), cFieldType, newEmptyNode())
    )

  result.add(
    quote do:
      type `exportedCItemIdent` {.exportc.} = object
  )
  # Replace the empty RecList with our fields
  let lastTypeSect = result[result.len - 1]
  for typeDef in lastTypeSect:
    if typeDef.kind == nnkTypeDef:
      let objTy = typeDef[2]
      if objTy.kind == nnkObjectTy:
        objTy[2] = cItemFields

  # 3. Emit encode proc (Nim item → CItem)
  let encodeProcIdent = ident("encode" & typeName & "ToCItem")
  let itemParam = ident("item")
  var encodeBody = newStmtList()
  for (fname, ftype) in fields:
    let fnameIdent = ident(fname)
    if ftype.toLowerAscii() in ["string", "cstring"]:
      encodeBody.add(
        quote do:
          result.`fnameIdent` = allocCStringCopy(`itemParam`.`fnameIdent`)
      )
    else:
      encodeBody.add(
        quote do:
          result.`fnameIdent` = `itemParam`.`fnameIdent`
      )

  result.add(
    quote do:
      proc `encodeProcIdent`*(`itemParam`: `typeIdent`): `cItemIdent` =
        `encodeBody`

  )

  # 4. Generate C header struct declaration
  var headerFields: seq[(string, string)] = @[]
  for (fname, ftype) in fields:
    headerFields.add((fname, nimTypeToCOutput(typeNodeOf(ftype))))
  appendHeaderDecl(generateCStruct(typeName & "CItem", headerFields))

  # 5. Generate plain C++ data struct + forward decl + detail::adopt(CItem)
  block:
    gApiCppForwardDecls.add("struct " & typeName & ";")

    var cppStruct = "struct " & typeName & " {\n"
    for (fname, ftype) in fields:
      let cppType = nimTypeToCpp(typeNodeOf(ftype))
      cppStruct.add("    " & cppType & " " & fname)
      if cppType in ["bool"]:
        cppStruct.add(" = false")
      elif cppType in [
        "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t",
        "uint64_t", "float", "double",
      ]:
        cppStruct.add(" = 0")
      cppStruct.add(";\n")
    cppStruct.add("};\n")
    gApiCppStructs.add(cppStruct)

    var adopt =
      "inline " & typeName & " adopt" & typeName & "(const ::" & typeName &
      "CItem& c) {\n"
    adopt.add("    " & typeName & " r;\n")
    for (fname, ftype) in fields:
      if ftype.toLowerAscii() in ["string", "cstring"]:
        adopt.add("    r." & fname & " = c." & fname & " ? c." & fname & " : \"\";\n")
      else:
        adopt.add("    r." & fname & " = c." & fname & ";\n")
    adopt.add("    return r;\n")
    adopt.add("}\n")
    gApiCppDetailAdopters.add(adopt)

  # 6. Generate Python ctypes Structure + dataclass (when -d:BrokerFfiApiGenPy)
  when defined(BrokerFfiApiGenPy):
    # ctypes Structure for CItem
    block:
      var pyCStruct = "class " & typeName & "CItem(ctypes.Structure):\n"
      pyCStruct.add("    _fields_ = [\n")
      for (fname, ftype) in fields:
        let ctField = nimTypeToCtypes(typeNodeOf(ftype))
        pyCStruct.add("        (\"" & fname & "\", " & ctField & "),\n")
      pyCStruct.add("    ]")
      gApiPyCtypesStructs.add(pyCStruct)

    # Python dataclass
    block:
      var pyDc = "@dataclass\n"
      pyDc.add("class " & typeName & ":\n")
      pyDc.add("    \"\"\"" & typeName & " data object.\"\"\"\n")
      for (fname, ftype) in fields:
        let pyType = nimTypeToPyAnnotation(typeNodeOf(ftype))
        let pyDefault = nimTypeToPyDefault(typeNodeOf(ftype))
        pyDc.add("    " & fname & ": " & pyType & " = " & pyDefault)
        pyDc.add("\n")
      gApiPyDataclasses.add(pyDc)

  # 7. Generate Rust struct + #[repr(C)] CItem (when -d:BrokerFfiApiGenRust)
  when defined(BrokerFfiApiGenRust):
    block:
      var rsFfi = "#[repr(C)]\n"
      rsFfi.add("#[derive(Debug)]\n")
      rsFfi.add("pub struct " & typeName & "CItem {\n")
      for (fname, ftype) in fields:
        rsFfi.add(
          "    pub " & fname & ": " & nimTypeToRustFfi(typeNodeOf(ftype)) & ",\n"
        )
      rsFfi.add("}")
      gApiRustFfiStructs.add(rsFfi)

    block:
      var rsSafe = "#[derive(Debug, Clone, Default)]\n"
      rsSafe.add("pub struct " & typeName & " {\n")
      for (fname, ftype) in fields:
        rsSafe.add("    pub " & fname & ": " & nimTypeToRust(typeNodeOf(ftype)) & ",\n")
      rsSafe.add("}")
      gApiRustStructs.add(rsSafe)

  # 8. Generate Go struct (when -d:BrokerFfiApiGenGo)
  when defined(BrokerFfiApiGenGo):
    block:
      var goSt = "type " & typeName & " struct {\n"
      for (fname, ftype) in fields:
        let goType = nimTypeToGo(typeNodeOf(ftype))
        # Capitalize first letter for export
        let exportedName =
          if fname.len > 0 and fname[0] >= 'a' and fname[0] <= 'z':
            chr(ord(fname[0]) - 32) & fname[1 ..^ 1]
          else:
            fname
        goSt.add("\t" & exportedName & " " & goType & "\n")
      goSt.add("}")
      gApiGoStructs.add(goSt)

  when defined(brokerDebug):
    echo result.repr

{.pop.}
