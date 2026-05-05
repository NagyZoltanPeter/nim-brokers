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

  # Register fields in compile-time accumulator
  var fields: seq[(string, string)] = @[]
  for i in 0 ..< parsed.fieldNames.len:
    fields.add(($parsed.fieldNames[i], $parsed.fieldTypes[i]))
  registerApiFfiStruct(typeName, fields)

  result = newStmtList()

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
    let cFieldType = toCFieldType(ident(ftype))
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
    headerFields.add((fname, nimTypeToCOutput(ident(ftype))))
  appendHeaderDecl(generateCStruct(typeName & "CItem", headerFields))

  # 5. Generate C++ struct with std::string fields + ctor from CItem
  block:
    var cppStruct = "struct " & typeName & " {\n"
    for (fname, ftype) in fields:
      let cppType = nimTypeToCpp(ident(ftype))
      cppStruct.add("    " & cppType & " " & fname)
      # Default initializers for non-class types
      if cppType in ["bool"]:
        cppStruct.add(" = false")
      elif cppType in [
        "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t",
        "uint64_t", "float", "double",
      ]:
        cppStruct.add(" = 0")
      cppStruct.add(";\n")
    cppStruct.add("    " & typeName & "() = default;\n")
    # Constructor from CItem
    cppStruct.add("    explicit " & typeName & "(const " & typeName & "CItem& c)")
    var ctorInits: seq[string] = @[]
    for (fname, ftype) in fields:
      if ftype.toLowerAscii() in ["string", "cstring"]:
        ctorInits.add(fname & "(c." & fname & " ? c." & fname & " : \"\")")
      else:
        ctorInits.add(fname & "(c." & fname & ")")
    if ctorInits.len > 0:
      cppStruct.add("\n        : " & ctorInits.join("\n        , "))
    cppStruct.add(" {}\n")
    cppStruct.add("};\n")
    gApiCppStructs.add(cppStruct)

  # 6. Generate Python ctypes Structure + dataclass (when -d:BrokerFfiApiGenPy)
  when defined(BrokerFfiApiGenPy):
    # ctypes Structure for CItem
    block:
      var pyCStruct = "class " & typeName & "CItem(ctypes.Structure):\n"
      pyCStruct.add("    _fields_ = [\n")
      for (fname, ftype) in fields:
        let ctField = nimTypeToCtypes(ident(ftype))
        pyCStruct.add("        (\"" & fname & "\", " & ctField & "),\n")
      pyCStruct.add("    ]")
      gApiPyCtypesStructs.add(pyCStruct)

    # Python dataclass
    block:
      var pyDc = "@dataclass\n"
      pyDc.add("class " & typeName & ":\n")
      pyDc.add("    \"\"\"" & typeName & " data object.\"\"\"\n")
      for (fname, ftype) in fields:
        let pyType = nimTypeToPyAnnotation(ident(ftype))
        let pyDefault = nimTypeToPyDefault(ident(ftype))
        pyDc.add("    " & fname & ": " & pyType & " = " & pyDefault)
        pyDc.add("\n")
      gApiPyDataclasses.add(pyDc)

  when defined(brokerDebug):
    echo result.repr

{.pop.}
