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
## ## Constraints
##
## - External types must be defined **before** the broker macro call site
##   (normal Nim compilation order).
## - Only `object` types can be introspected. Non-object types (enums,
##   distinct, etc.) pass through without field registration.

{.push raises: [].}

import std/[macros, strutils]
import ./api_schema, ./api_type

export api_schema, api_type

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

    # seq[T] where T is a custom object (e.g. `devices: seq[DeviceInfo]`)
    elif fieldType.kind == nnkBracketExpr and fieldType.len >= 2 and
        $fieldType[0] == "seq":
      let elemSym = fieldType[1]
      if elemSym.kind == nnkSym and not isNimPrimitive($elemSym):
        let elemImpl = getTypeImpl(elemSym)
        if elemImpl.kind == nnkObjectTy:
          result.add(elemSym)

proc buildSyntheticApiTypeBody(typeName: string, fields: seq[(string, string)]): NimNode {.compileTime.} =
  ## Construct an AST body equivalent to what `ApiType:` receives, e.g.:
  ##   type TypeName = object
  ##     field1*: Type1
  ##     field2*: Type2
  ## This allows reuse of `generateApiType` for auto-resolved external types.
  var recList = newTree(nnkRecList)
  for (fname, ftype) in fields:
    recList.add(
      newTree(nnkIdentDefs,
        postfix(ident(fname), "*"),
        ident(ftype),
        newEmptyNode()
      )
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
  ## This macro is emitted by Phase 1 (`emitAutoRegistrations`) and
  ## should not be called directly by user code.
  result = newStmtList()

  let actualSym = resolveActualSym(T)
  if actualSym.isNil:
    return result

  let typeName = $actualSym
  if isTypeRegistered(typeName) or isNimPrimitive(typeName):
    return result

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
  ## Adds ident nodes for `seq[T]` and plain custom types.
  if ft.kind == nnkEmpty:
    return
  # seq[T]
  if ft.kind == nnkBracketExpr and ft.len >= 2 and $ft[0] == "seq":
    let elemName = $ft[1]
    if not isNimPrimitive(elemName):
      result.add(ft[1])
  # Plain custom type
  elif ft.kind == nnkIdent and not isNimPrimitive($ft):
    result.add(ft)

proc discoverExternalTypes*(body: NimNode): seq[NimNode] {.compileTime.} =
  ## Scan an untyped macro body for references to external types.
  ## Returns ident nodes for each type that needs resolution.
  ##
  ## Detects:
  ## - `seq[T]` fields in type definitions where T is not a primitive
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
