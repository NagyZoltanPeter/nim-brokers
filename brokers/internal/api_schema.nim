## api_schema
## ----------
## Compile-time type registry for FFI API code generation.
##
## This module provides a language-neutral schema that broker macros populate
## and codegen modules consume. It replaces the previous `gApiFfiStructs`
## registry with a richer type model that supports auto-resolution of
## external types (no separate `ApiType` macro needed).
##
## The registry stores field information for types used across the FFI boundary,
## primarily needed for `seq[T]` element encoding/decoding and nested object
## marshalling.

{.push raises: [].}

import std/[macros, strutils]

type
  ApiFieldDef* = object ## A single field in a type definition.
    name*: string
    nimType*: string ## "int64", "string", "bool", "seq[DeviceInfo]", etc.
    isSeq*: bool ## true when nimType starts with "seq["
    seqElementType*: string ## e.g. "DeviceInfo" when isSeq
    isCustomObject*: bool ## true when type resolves to an object (not primitive)

  ApiTypeEntry* = object ## A registered type in the FFI schema.
    name*: string ## "DeviceInfo"
    fields*: seq[ApiFieldDef] ## field definitions
    isAlias*: bool ## true for `type MyEvent = DeviceInfo`
    aliasTarget*: string ## "DeviceInfo" when isAlias

# ---------------------------------------------------------------------------
# Compile-time type registry
# ---------------------------------------------------------------------------

var gApiTypeRegistry* {.compileTime.}: seq[ApiTypeEntry] = @[]
  ## All types registered for FFI code generation.
  ## Populated by auto-resolution (api_type_resolver) or legacy ApiType macro.
  ## Consumed by codegen modules when processing seq[T] fields.

# ---------------------------------------------------------------------------
# Primitive type detection
# ---------------------------------------------------------------------------

const nimPrimitiveTypes* = [
  "string", "cstring", "char", "bool", "int", "int8", "int16", "int32", "int64", "uint",
  "uint8", "uint16", "uint32", "uint64", "float", "float32", "float64", "byte",
]

proc isNimPrimitive*(typeName: string): bool {.compileTime.} =
  ## Returns true if `typeName` is a built-in Nim primitive type.
  typeName.toLowerAscii() in nimPrimitiveTypes

# ---------------------------------------------------------------------------
# Registry operations
# ---------------------------------------------------------------------------

proc isTypeRegistered*(name: string): bool {.compileTime.} =
  ## Check if a type is already in the registry.
  for entry in gApiTypeRegistry:
    if entry.name == name:
      return true
  false

proc lookupTypeEntry*(name: string): ApiTypeEntry {.compileTime.} =
  ## Lookup a type entry by name. Returns the entry or triggers a compile error.
  for entry in gApiTypeRegistry:
    if entry.name == name:
      return entry
  error(
    "Type '" & name & "' not registered in FFI schema. " &
      "Define it as a plain Nim type before using it in a broker macro, " &
      "or declare it with `ApiType:` for explicit registration."
  )

proc lookupTypeFields*(name: string): seq[(string, string)] {.compileTime.} =
  ## Backward-compatible lookup returning (fieldName, nimTypeName) tuples.
  ## This is the drop-in replacement for the old `lookupFfiStruct()`.
  let entry = lookupTypeEntry(name)
  for field in entry.fields:
    result.add((field.name, field.nimType))

proc registerTypeEntry*(entry: ApiTypeEntry) {.compileTime.} =
  ## Register a type in the schema. Skips if already registered.
  if not isTypeRegistered(entry.name):
    gApiTypeRegistry.add(entry)

# ---------------------------------------------------------------------------
# Field construction helpers
# ---------------------------------------------------------------------------

proc makeFieldDef*(name, nimType: string): ApiFieldDef {.compileTime.} =
  ## Construct an ApiFieldDef from name and type strings.
  result.name = name
  result.nimType = nimType
  let lower = nimType.toLowerAscii()
  if lower.startsWith("seq[") and lower.endsWith("]"):
    result.isSeq = true
    result.seqElementType = nimType[4 ..^ 2] # strip "seq[" and "]"
  if not isNimPrimitive(nimType) and not result.isSeq:
    result.isCustomObject = true

proc makeTypeEntry*(
    name: string, fields: seq[ApiFieldDef], isAlias = false, aliasTarget = ""
): ApiTypeEntry {.compileTime.} =
  ## Construct an ApiTypeEntry.
  result.name = name
  result.fields = fields
  result.isAlias = isAlias
  result.aliasTarget = aliasTarget

# ---------------------------------------------------------------------------
# Backward compatibility: bridge to old gApiFfiStructs format
# ---------------------------------------------------------------------------

proc registerFromFieldTuples*(
    typeName: string, fields: seq[(string, string)]
) {.compileTime.} =
  ## Register a type from (fieldName, nimTypeName) tuples.
  ## Used by the legacy ApiType macro and during migration.
  if isTypeRegistered(typeName):
    return
  var fieldDefs: seq[ApiFieldDef] = @[]
  for (fname, ftype) in fields:
    fieldDefs.add(makeFieldDef(fname, ftype))
  registerTypeEntry(makeTypeEntry(typeName, fieldDefs))

{.pop.}
