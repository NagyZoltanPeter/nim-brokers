## api_type_resolver
## -----------------
## Two-phase external type introspection for FFI API broker macros.
##
## When a broker macro encounters a reference to an external type (e.g.
## `seq[DeviceInfo]` where `DeviceInfo` is a plain Nim type defined outside
## the macro body), this module resolves its fields at compile time and
## registers it in the API schema.
##
## ## Mechanism
##
## Phase 1 (called from an `untyped` broker macro):
##   `discoverExternalTypes(body)` scans the raw AST for type identifiers
##   that are not Nim primitives. Returns ident nodes.
##
## Phase 2 (typed macro expansion):
##   `autoRegisterApiType(T: typed)` receives a resolved type symbol,
##   calls `getTypeImpl()` to extract its fields, recursively resolves
##   nested object types, and registers everything in `gApiTypeRegistry`.
##
## ## Supported type kinds
##
## - `object` types — field introspection and CItem generation
## - `enum` types — value extraction and C enum generation
## - `distinct` types — base type resolution and C typedef generation
## - Type aliases — base type resolution and C typedef generation

{.push raises: [].}

import std/[macros, strutils]
import ./api_schema, ./api_type
import ./api_codegen_c

export api_schema, api_type
export api_codegen_c

# ---------------------------------------------------------------------------
# Phase 2: Typed macro that resolves a single external type
# ---------------------------------------------------------------------------

proc resolveActualSym(T: NimNode): NimNode {.compileTime.} =
  ## Get the actual type symbol regardless of how T was passed.
  ## Handles both typedesc[X] (from typed parameter) and direct symbols
  ## (from recursive calls within the typed phase).
  let impl = getTypeImpl(T)
  case impl.kind
  of nnkBracketExpr:
    # typedesc[X] -> return X
    if impl.len >= 2:
      impl[1]
    else:
      nil
  of nnkObjectTy:
    # Already resolved; T itself is the symbol
    T
  of nnkEnumTy:
    T
  of nnkDistinctTy:
    T
  of nnkSym:
    T
  else:
    nil

proc extractFieldsFromSym(sym: NimNode): seq[(string, string)] {.compileTime.} =
  ## Extract (fieldName, fieldTypeName) from a resolved type symbol.
  let typeImpl = getTypeImpl(sym)
  let obj =
    if typeImpl.kind == nnkObjectTy:
      typeImpl
    elif typeImpl.kind == nnkBracketExpr and typeImpl.len >= 2:
      getTypeImpl(typeImpl[1])
    else:
      nil

  if obj.isNil or obj.kind != nnkObjectTy:
    return @[]

  let recList = obj[2]
  if recList.kind != nnkRecList:
    return @[]

  for field in recList:
    if field.kind != nnkIdentDefs:
      continue
    let fieldType = field[field.len - 2]
    if fieldType.kind == nnkEmpty:
      continue
    for i in 0 ..< field.len - 2:
      if field[i].kind == nnkEmpty:
        continue
      result.add(($field[i], repr(fieldType)))

proc extractEnumValues(sym: NimNode): seq[(string, int)] {.compileTime.} =
  ## Walk nnkEnumTy children to get (name, ordinal) pairs.
  let typeImpl = getTypeImpl(sym)
  let enumTy =
    if typeImpl.kind == nnkEnumTy:
      typeImpl
    elif typeImpl.kind == nnkBracketExpr and typeImpl.len >= 2:
      getTypeImpl(typeImpl[1])
    else:
      nil

  if enumTy.isNil or enumTy.kind != nnkEnumTy:
    return @[]

  var ordinal = 0
  for i in 1 ..< enumTy.len: # skip first child (empty node)
    let child = enumTy[i]
    case child.kind
    of nnkSym:
      result.add(($child, ordinal))
      inc ordinal
    of nnkEnumFieldDef:
      let fieldName = $child[0]
      let fieldVal = int(child[1].intVal)
      result.add((fieldName, fieldVal))
      ordinal = fieldVal + 1
    else:
      discard

proc resolveAliasBase(sym: NimNode): string {.compileTime.} =
  ## Follows alias/distinct chains to the underlying primitive name.
  let typeImpl = getTypeImpl(sym)
  if typeImpl.kind == nnkDistinctTy:
    let base = typeImpl[0]
    return $base
  # For aliases, getTypeInst gives us the target
  let typeInst = getTypeInst(sym)
  if typeInst.kind == nnkBracketExpr and typeInst.len >= 2:
    return $typeInst[1]
  if typeInst.kind == nnkSym:
    return $typeInst
  return $sym

proc collectNestedTypeNodes(sym: NimNode): seq[NimNode] {.compileTime.} =
  ## Walk the fields of a resolved type symbol and return NimNodes for
  ## any nested custom object types or seq[T] element types that need
  ## recursive registration.
  let typeImpl = getTypeImpl(sym)
  let obj =
    if typeImpl.kind == nnkObjectTy:
      typeImpl
    elif typeImpl.kind == nnkBracketExpr and typeImpl.len >= 2:
      getTypeImpl(typeImpl[1])
    else:
      nil

  if obj.isNil or obj.kind != nnkObjectTy:
    return @[]

  let recList = obj[2]
  if recList.kind != nnkRecList:
    return @[]

  for field in recList:
    if field.kind != nnkIdentDefs:
      continue
    let fieldType = field[field.len - 2]
    if fieldType.kind == nnkEmpty:
      continue

    # Direct custom object field (e.g. `address: Address`)
    if fieldType.kind == nnkSym and not isNimPrimitive($fieldType):
      let innerImpl = getTypeImpl(fieldType)
      if innerImpl.kind == nnkObjectTy:
        result.add(fieldType)
      elif innerImpl.kind == nnkEnumTy:
        result.add(fieldType)
      elif innerImpl.kind == nnkDistinctTy:
        result.add(fieldType)
      else:
        # Could be an alias — check if it resolves to something different
        let instName = $getTypeInst(fieldType)
        if instName != $fieldType and not isNimPrimitive(instName):
          result.add(fieldType)

    # seq[T] where T is a custom type (e.g. `devices: seq[DeviceInfo]`)
    elif fieldType.kind == nnkBracketExpr and fieldType.len >= 2 and
        $fieldType[0] == "seq":
      let elemSym = fieldType[1]
      if elemSym.kind == nnkSym and not isNimPrimitive($elemSym):
        let elemImpl = getTypeImpl(elemSym)
        if elemImpl.kind == nnkObjectTy:
          result.add(elemSym)
        elif elemImpl.kind == nnkEnumTy:
          result.add(elemSym)

    # array[N, T] where T is a custom type
    elif fieldType.kind == nnkBracketExpr and fieldType.len == 3 and
        $fieldType[0] == "array":
      let elemSym = fieldType[2]
      if elemSym.kind == nnkSym and not isNimPrimitive($elemSym):
        let elemImpl = getTypeImpl(elemSym)
        if elemImpl.kind == nnkObjectTy:
          result.add(elemSym)
        elif elemImpl.kind == nnkEnumTy:
          result.add(elemSym)

proc buildSyntheticApiTypeBody(
    typeName: string, fields: seq[(string, string)]
): NimNode {.compileTime.} =
  ## Construct an AST body equivalent to what `ApiType:` receives, e.g.:
  ##   type TypeName = object
  ##     field1*: Type1
  ##     field2*: Type2
  ## This allows reuse of `generateApiType` for auto-resolved external types.
  var recList = newTree(nnkRecList)
  for (fname, ftype) in fields:
    recList.add(
      newTree(nnkIdentDefs, postfix(ident(fname), "*"), ident(ftype), newEmptyNode())
    )
  let objTy = newTree(nnkObjectTy, newEmptyNode(), newEmptyNode(), recList)
  let typeDef = newTree(nnkTypeDef, ident(typeName), newEmptyNode(), objTy)
  let typeSect = newTree(nnkTypeSection, typeDef)
  result = newStmtList(typeSect)

macro autoRegisterApiType*(T: typed): untyped =
  ## Phase 2: Receives a resolved type symbol, extracts fields,
  ## recursively processes nested types, registers in the schema,
  ## and generates CItem type + encode proc + C/C++/Python codegen.
  ##
  ## Handles object types (full CItem generation), enum types (C enum
  ## generation), and alias/distinct types (C typedef generation).
  result = newStmtList()

  let actualSym = resolveActualSym(T)
  if actualSym.isNil:
    return result

  let typeName = $actualSym
  if isTypeRegistered(typeName) or isNimPrimitive(typeName):
    return result

  let typeImpl = getTypeImpl(actualSym)

  # Check for enum types
  block checkEnum:
    let enumTy =
      if typeImpl.kind == nnkEnumTy:
        typeImpl
      elif typeImpl.kind == nnkBracketExpr and typeImpl.len >= 2:
        let inner = getTypeImpl(typeImpl[1])
        if inner.kind == nnkEnumTy: inner else: nil
      else:
        nil
    if not enumTy.isNil:
      let values = extractEnumValues(actualSym)
      var apiValues: seq[ApiEnumValue] = @[]
      for (name, ordinal) in values:
        apiValues.add(ApiEnumValue(name: name, ordinal: ordinal))
      registerTypeEntry(makeEnumEntry(typeName, apiValues))

      # Generate C enum typedef in header
      var enumDecl = "typedef enum {\n"
      let prefix = toSnakeCase(typeName).toUpperAscii()
      for v in apiValues:
        enumDecl.add(
          "    " & prefix & "_" & toSnakeCase(v.name).toUpperAscii() & " = " & $v.ordinal &
            ",\n"
        )
      enumDecl.add("} " & typeName & ";\n")
      appendHeaderDecl(enumDecl)

      # Generate C++ enum (inherits from .h include, but add to cpp structs
      # for namespace awareness)
      # No separate C++ struct needed — C enum typedef is used directly

      # Generate Python IntEnum class
      when defined(BrokerFfiApiGenPy):
        var pyEnum = "class " & typeName & "(enum.IntEnum):\n"
        pyEnum.add("    \"\"\"" & typeName & " — generated from Nim enum.\"\"\"\n")
        for v in apiValues:
          pyEnum.add(
            "    " & prefix & "_" & toSnakeCase(v.name).toUpperAscii() & " = " &
              $v.ordinal & "\n"
          )
        gApiPyTypedefs.add(pyEnum)

      # Emit recursive calls for nested enum dependencies (rare but possible)
      return result

  # Check for distinct types
  if typeImpl.kind == nnkDistinctTy:
    let baseName = resolveAliasBase(actualSym)
    registerTypeEntry(makeAliasEntry(typeName, baseName, atkDistinct))

    # Generate C typedef in header
    let cBase = nimTypeToCSuffix(ident(baseName))
    appendHeaderDecl("typedef " & cBase & " " & typeName & ";\n")

    # Generate Python type alias
    when defined(BrokerFfiApiGenPy):
      let pyBase = nimTypeToPyAnnotation(ident(baseName))
      gApiPyTypedefs.add(typeName & " = " & pyBase & "  # distinct " & baseName)

    return result

  # Check for alias types (sym that resolves to another sym/primitive)
  block checkAlias:
    let typeInst = getTypeInst(actualSym)
    if typeInst.kind == nnkBracketExpr and typeInst.len >= 2:
      let targetName = $typeInst[1]
      if targetName != typeName:
        registerTypeEntry(makeAliasEntry(typeName, targetName, atkAlias))
        let cBase = nimTypeToCSuffix(ident(targetName))
        appendHeaderDecl("typedef " & cBase & " " & typeName & ";\n")
        return result

  # Object types — existing behavior
  let fields = extractFieldsFromSym(actualSym)
  if fields.len == 0:
    return result

  # Emit recursive calls for nested types (depth-first: dependencies first)
  let nestedNodes = collectNestedTypeNodes(actualSym)
  for nestedSym in nestedNodes:
    let nestedName = $nestedSym
    if not isTypeRegistered(nestedName) and not isNimPrimitive(nestedName):
      result.add(newCall(ident("autoRegisterApiType"), nestedSym))

  # Register this type in the schema
  registerFromFieldTuples(typeName, fields)

  # Generate CItem type, encode proc, C/C++/Python codegen —
  # same as ApiType but driven from resolved fields.
  # Pass emitTypeDefinition=false since the type is already defined externally.
  let syntheticBody = buildSyntheticApiTypeBody(typeName, fields)
  result.add(generateApiType(syntheticBody, emitTypeDefinition = false))

# ---------------------------------------------------------------------------
# Phase 1: Scan untyped AST for external type references
# ---------------------------------------------------------------------------

proc scanTypeNode(ft: NimNode, result: var seq[NimNode]) {.compileTime.} =
  ## Check a single type node for external type references.
  ## Adds ident nodes for `seq[T]`, `array[N, T]`, and plain custom types.
  if ft.kind == nnkEmpty:
    return
  # seq[T]
  if ft.kind == nnkBracketExpr and ft.len >= 2 and $ft[0] == "seq":
    let elemName = $ft[1]
    if not isNimPrimitive(elemName):
      result.add(ft[1])
  # array[N, T]
  elif ft.kind == nnkBracketExpr and ft.len == 3 and $ft[0] == "array":
    let elemName = $ft[2]
    if not isNimPrimitive(elemName):
      result.add(ft[2])
  # Plain custom type
  elif ft.kind == nnkIdent and not isNimPrimitive($ft):
    result.add(ft)

proc discoverExternalTypes*(body: NimNode): seq[NimNode] {.compileTime.} =
  ## Scan an untyped macro body for references to external types.
  ## Returns ident nodes for each type that needs resolution.
  ##
  ## Detects:
  ## - `seq[T]` fields in type definitions where T is not a primitive
  ## - `array[N, T]` fields where T is not a primitive
  ## - Plain custom type fields (`field: CustomType`)
  ## - Type aliases (`type MyEvent = ExternalType`)
  ## - `seq[T]` and custom types in proc signature parameters
  var seen: seq[string] = @[]

  for stmt in body:
    if stmt.kind == nnkTypeSection:
      for def in stmt:
        if def.kind != nnkTypeDef:
          continue
        let rhs = def[2]

        if rhs.kind == nnkObjectTy:
          # Inline object: scan fields
          let recList = rhs[2]
          if recList.kind != nnkRecList:
            continue
          for field in recList:
            if field.kind != nnkIdentDefs:
              continue
            let ft = field[field.len - 2]
            scanTypeNode(ft, result)
        elif rhs.kind == nnkIdent:
          # Type alias: `type MyEvent = ExternalType`
          let aliasTarget = $rhs
          if not isNimPrimitive(aliasTarget):
            result.add(rhs)
    elif stmt.kind == nnkProcDef:
      # Scan proc signature parameters for external types
      let params = stmt.params
      for i in 1 ..< params.len:
        let paramDef = params[i]
        if paramDef.kind == nnkIdentDefs:
          let ft = paramDef[paramDef.len - 2]
          scanTypeNode(ft, result)

  # Deduplicate (keep first occurrence)
  var deduped: seq[NimNode] = @[]
  for node in result:
    let name = $node
    if name notin seen:
      seen.add(name)
      deduped.add(node)
  result = deduped

proc emitAutoRegistrations*(externalIdents: seq[NimNode]): NimNode {.compileTime.} =
  ## Generate `autoRegisterApiType(Ident)` calls for discovered external types.
  ## These compile as typed macro invocations, triggering Phase 2 resolution.
  result = newStmtList()
  for typeIdent in externalIdents:
    result.add(newCall(ident("autoRegisterApiType"), typeIdent))

{.pop.}
