## api_codegen_c
## --------------
## C header code generation for the FFI API system.
##
## Owns:
## - C type mapping procs (Nim → C types)
## - Compile-time accumulators for C header declarations
## - `generateCHeaderFile` — writes the pure C `.h` file
##
## Used by broker macros (`api_request_broker`, `api_event_broker`) and
## `api_type` to append C declarations, then by `api_library` to generate
## the final header file.

{.push raises: [].}

import std/[compilesettings, macros, os, strutils]
import ./api_schema

export api_schema

# ---------------------------------------------------------------------------
# Forward imports — shared helpers from api_common
# ---------------------------------------------------------------------------
# We avoid importing api_common to break the dependency direction:
# codegen modules should not depend on the monolith.
# Instead we define what we need locally or accept it as parameters.

# ---------------------------------------------------------------------------
# Compile-time C type mapping
# ---------------------------------------------------------------------------

proc isSeqType*(nimType: NimNode): bool {.compileTime.} =
  ## Returns true if the type node represents `seq[T]`.
  nimType.kind == nnkBracketExpr and nimType.len == 2 and
    ($nimType[0]).toLowerAscii() == "seq"

proc seqItemTypeName*(nimType: NimNode): string {.compileTime.} =
  ## Extracts the element type name from a `seq[T]` node.
  assert isSeqType(nimType)
  $nimType[1]

proc isArrayTypeNode*(nimType: NimNode): bool {.compileTime.} =
  ## Returns true if the type node represents `array[N, T]`.
  nimType.kind == nnkBracketExpr and nimType.len == 3 and
    ($nimType[0]).toLowerAscii() == "array"

proc arrayNodeSize*(nimType: NimNode): int {.compileTime.} =
  ## Extracts N from an `array[N, T]` node.
  assert isArrayTypeNode(nimType)
  if nimType[1].kind == nnkIntLit:
    int(nimType[1].intVal)
  else:
    error("array size must be an integer literal for FFI codegen", nimType[1])
    0

proc arrayNodeElemName*(nimType: NimNode): string {.compileTime.} =
  ## Extracts the element type name from an `array[N, T]` node.
  assert isArrayTypeNode(nimType)
  $nimType[2]

proc nimTypeToCSuffix*(nimType: NimNode): string {.compileTime.}

proc nimTypeToCSuffixIdent(name: string): string {.compileTime.} =
  ## Internal: map a plain identifier name to its C type suffix.
  ## Checks the schema registry for enums, aliases, and distinct types.
  case name.toLowerAscii()
  of "int", "int32":
    "int32_t"
  of "int8":
    "int8_t"
  of "int16":
    "int16_t"
  of "int64":
    "int64_t"
  of "uint", "uint32":
    "uint32_t"
  of "uint8":
    "uint8_t"
  of "uint16":
    "uint16_t"
  of "uint64":
    "uint64_t"
  of "float", "float64":
    "double"
  of "float32":
    "float"
  of "bool":
    "bool"
  of "string":
    "const char*"
  of "cstring":
    "const char*"
  of "brokercontext":
    "uint32_t"
  of "pointer":
    "void*"
  of "byte":
    "uint8_t"
  else:
    # Check schema registry for aliases/distinct types
    if isEnumRegistered(name):
      name # enum typedef name is used directly
    elif isAliasOrDistinctRegistered(name):
      # Recurse on the underlying type
      nimTypeToCSuffix(ident(resolveUnderlyingType(name)))
    else:
      name # user-defined struct name

proc nimTypeToCSuffix*(nimType: NimNode): string {.compileTime.} =
  ## Returns the C type suffix for struct field declarations.
  ## For array[N,T] returns "elemType[N]" — caller must detect "[" suffix
  ## and use `baseType fieldName[N]` syntax in struct generation.
  case nimType.kind
  of nnkIdent:
    nimTypeToCSuffixIdent($nimType)
  of nnkBracketExpr:
    if isSeqType(nimType):
      let elemName = seqItemTypeName(nimType)
      if isNimPrimitive(elemName):
        # seq[primitive] → direct pointer to primitive type
        nimTypeToCSuffixIdent(elemName) & "*"
      else:
        elemName & "CItem*"
    elif isArrayTypeNode(nimType):
      let n = arrayNodeSize(nimType)
      let elemName = arrayNodeElemName(nimType)
      nimTypeToCSuffixIdent(elemName) & "[" & $n & "]"
    else:
      error(
        "Generic types other than seq[T] and array[N,T] are not yet supported in API broker FFI",
        nimType,
      )
  else:
    error("Unsupported type node kind for C mapping: " & $nimType.kind, nimType)

proc nimTypeToCOutput*(nimType: NimNode): string {.compileTime.} =
  ## Returns the C type for output/return fields (strings become char*).
  let base = nimTypeToCSuffix(nimType)
  if base == "const char*": "char*" else: base

proc nimTypeToCInput*(nimType: NimNode): string {.compileTime.} =
  ## Returns the C type for input/parameter fields (strings become const char*).
  nimTypeToCSuffix(nimType)

# ---------------------------------------------------------------------------
# Compile-time accumulators
# ---------------------------------------------------------------------------

var gApiHeaderDeclarations* {.compileTime.}: seq[string] = @[]

const ApiLibPrefixPlaceholder* = "__BROKERS_API_LIB_PREFIX__"

type ApiCExportWrapper* =
  tuple[
    publicSuffix: string,
    rawName: string,
    returnType: string,
    params: seq[(string, string)],
  ]

var gApiCExportWrappers* {.compileTime.}: seq[ApiCExportWrapper] = @[]

# ---------------------------------------------------------------------------
# Accumulator helpers
# ---------------------------------------------------------------------------

proc appendHeaderDecl*(decl: string) {.compileTime.} =
  gApiHeaderDeclarations.add(decl)

proc registerApiCExportWrapper*(
    publicSuffix: string,
    rawName: string,
    returnType: string,
    params: seq[(string, string)],
) {.compileTime.} =
  gApiCExportWrappers.add((publicSuffix, rawName, returnType, params))

# ---------------------------------------------------------------------------
# C code generation helpers
# ---------------------------------------------------------------------------

proc generateCStruct*(
    structName: string, fields: seq[(string, string)]
): string {.compileTime.} =
  ## Generates a C struct definition string.
  ## Handles array fields encoded as "elemType[N]" in fieldType.
  result = "typedef struct {\n"
  for (fieldName, fieldType) in fields:
    let bracketPos = fieldType.find('[')
    if bracketPos >= 0:
      # Array type: "int32_t[3]" → "int32_t fieldName[3]"
      let baseType = fieldType[0 ..< bracketPos]
      let arraySuffix = fieldType[bracketPos .. ^1]
      result.add("    " & baseType & " " & fieldName & arraySuffix & ";\n")
    else:
      result.add("    " & fieldType & " " & fieldName & ";\n")
  result.add("} " & structName & ";\n")

proc generateCFuncProto*(
    funcName: string, returnType: string, params: seq[(string, string)]
): string {.compileTime.} =
  ## Generates a C function prototype string.
  result = returnType & " " & funcName & "("
  if params.len == 0:
    result.add("void")
  else:
    var first = true
    for (paramName, paramType) in params:
      if not first:
        result.add(", ")
      first = false
      result.add(paramType & " " & paramName)
  result.add(");\n")

# ---------------------------------------------------------------------------
# Naming helpers
# ---------------------------------------------------------------------------

proc apiPublicCName*(suffix: string): string {.compileTime.} =
  ApiLibPrefixPlaceholder & suffix

proc toSnakeCase*(name: string): string {.compileTime.} =
  ## Converts PascalCase/camelCase to snake_case.
  result = ""
  for i, ch in name:
    if ch in {'A' .. 'Z'}:
      if i > 0 and name[i - 1] notin {'A' .. 'Z', '_'}:
        result.add('_')
      result.add(chr(ord(ch) + 32))
    else:
      result.add(ch)

proc generateCEnum*(
    enumName: string, values: seq[tuple[name: string, ordinal: int]]
): string {.compileTime.} =
  ## Generates a C typedef enum definition.
  ## Values are prefixed with SCREAMING_SNAKE_CASE enum name to avoid
  ## global namespace collisions in C.
  let prefix = toSnakeCase(enumName).toUpperAscii()
  result = "typedef enum {\n"
  for v in values:
    result.add(
      "    " & prefix & "_" & toSnakeCase(v.name).toUpperAscii() & " = " & $v.ordinal &
        ",\n"
    )
  result.add("} " & enumName & ";\n")

# ---------------------------------------------------------------------------
# Output directory helpers
# ---------------------------------------------------------------------------

proc detectOutputDir*(overrideOutDir = ""): string {.compileTime.} =
  ## Resolves the compiler output directory for generated artifacts.
  if overrideOutDir.len > 0:
    return overrideOutDir

  let configuredOutDir = querySetting(SingleValueSetting.outDir)
  if configuredOutDir.len > 0:
    return configuredOutDir

  let configuredOutFile = querySetting(SingleValueSetting.outFile)
  if configuredOutFile.len > 0:
    let candidateDir = splitFile(configuredOutFile).dir
    if candidateDir.len > 0:
      return candidateDir

  return ""

{.pop.} # temporarily lift raises:[] for compile-time proc using writeFile

proc ensureGeneratedOutputDir*(outDir: string) {.compileTime, raises: [].} =
  if outDir.len == 0 or dirExists(outDir):
    return
  try:
    createDir(outDir)
  except CatchableError:
    error(
      "Failed to create generated output directory '" & outDir & "': " &
        getCurrentExceptionMsg()
    )

# ---------------------------------------------------------------------------
# C header file generation
# ---------------------------------------------------------------------------

proc generateCHeaderFile*(outDir: string, libName: string) {.compileTime, raises: [].} =
  ## Writes the pure C header file (.h).
  ## Contains only C-compatible declarations (structs, function prototypes).
  ensureGeneratedOutputDir(outDir)
  let guardName = libName.toUpperAscii().replace("-", "_") & "_H"
  let headerPath =
    if outDir.len > 0:
      outDir & "/" & libName & ".h"
    else:
      libName & ".h"
  let apiPrefix = libName & "_"
  var header = "#ifndef " & guardName & "\n"
  header.add("#define " & guardName & "\n\n")
  header.add("#include <stdint.h>\n")
  header.add("#include <stdbool.h>\n")
  header.add("#include <stddef.h>\n\n")
  header.add("#ifdef __cplusplus\nextern \"C\" {\n#endif\n\n")
  for decl in gApiHeaderDeclarations:
    header.add(decl.replace(ApiLibPrefixPlaceholder, apiPrefix))
    header.add("\n")
  header.add("\n#ifdef __cplusplus\n}\n#endif\n\n")
  header.add("#endif /* " & guardName & " */\n")
  try:
    writeFile(headerPath, header)
  except IOError:
    error(
      "Failed to write generated header file '" & headerPath & "': " &
        getCurrentExceptionMsg()
    )

{.push raises: [].}
{.pop.}
