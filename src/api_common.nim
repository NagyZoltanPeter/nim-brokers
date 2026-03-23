## API Common
## ----------
## Shared utilities for FFI API broker code generation.
## Provides C type mapping, encode/decode generation, header accumulation,
## and runtime memory helpers for the FFI boundary.
##
## This module is only used when compiling with `-d:BrokerFfiApi`.

{.push raises: [].}

import std/[compilesettings, macros, os, strutils]

# ---------------------------------------------------------------------------
# Compile-time seq[T] type helpers (must precede type-mapping procs)
# ---------------------------------------------------------------------------

proc isSeqType*(nimType: NimNode): bool {.compileTime.} =
  ## Returns true if the type node represents `seq[T]`.
  nimType.kind == nnkBracketExpr and nimType.len == 2 and
    ($nimType[0]).toLowerAscii() == "seq"

proc seqItemTypeName*(nimType: NimNode): string {.compileTime.} =
  ## Extracts the element type name from a `seq[T]` node.
  assert isSeqType(nimType)
  $nimType[1]

# ---------------------------------------------------------------------------
# Compile-time C type mapping
# ---------------------------------------------------------------------------

proc nimTypeToCSuffix*(nimType: NimNode): string {.compileTime.} =
  ## Returns the C type suffix for use in struct field declarations.
  ## Does not handle pointer indirection for input vs output — that's
  ## handled by the caller.
  case nimType.kind
  of nnkIdent:
    let name = ($nimType).toLowerAscii()
    case name
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
    else:
      # Assume it's a user-defined type — use its sanitized name as a C struct
      $nimType
  of nnkBracketExpr:
    if isSeqType(nimType):
      seqItemTypeName(nimType) & "CItem*"
    else:
      error(
        "Generic types other than seq[T] are not yet supported in API broker FFI",
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

proc isCStringType*(nimType: NimNode): bool {.compileTime.} =
  ## Returns true if the Nim type maps to a C string type.
  if nimType.kind == nnkIdent:
    let name = ($nimType).toLowerAscii()
    name == "string" or name == "cstring"
  else:
    false

proc toCFieldType*(nimType: NimNode): NimNode {.compileTime.} =
  ## Returns the Nim type to use in the C-compatible struct.
  ## string → cstring, int → cint, etc.
  ## seq[T] → pointer (raw pointer to array; paired with a _count field).
  if nimType.kind == nnkBracketExpr:
    if isSeqType(nimType):
      return ident("pointer")
    else:
      return copyNimTree(nimType)
  if nimType.kind == nnkIdent:
    let name = ($nimType).toLowerAscii()
    case name
    of "string":
      ident("cstring")
    of "int", "int32":
      ident("cint")
    of "int8":
      ident("int8")
    of "int16":
      ident("int16")
    of "int64":
      ident("int64")
    of "uint", "uint32":
      ident("cuint")
    of "uint8":
      ident("uint8")
    of "uint16":
      ident("uint16")
    of "uint64":
      ident("uint64")
    of "float", "float64":
      ident("cdouble")
    of "float32":
      ident("cfloat")
    of "bool":
      ident("bool")
    of "brokercontext":
      ident("uint32")
    of "pointer":
      ident("pointer")
    else:
      copyNimTree(nimType)
  else:
    copyNimTree(nimType)

# ---------------------------------------------------------------------------
# Compile-time header accumulator
# ---------------------------------------------------------------------------

var gApiHeaderDeclarations* {.compileTime.}: seq[string] = @[]
var gApiLibraryName* {.compileTime.}: string = ""

# ---------------------------------------------------------------------------
# Compile-time accumulators for delivery thread event system
# ---------------------------------------------------------------------------

var gApiEventTypeCounter* {.compileTime.}: int = 0
  ## Auto-incrementing type ID for EventBroker(API) types.
  ## NOTE: Must be incremented directly (not via a helper proc) because the
  ## Nim VM does not persist side effects from called compileTime procs.

var gApiSharedBrokerGenerated* {.compileTime.}: bool = false
  ## Flag: has the shared RegisterEventListenerResult RequestBroker been emitted?

var gApiEventHandlerEntries* {.compileTime.}: seq[(int, string)] =
  @[] ## Accumulates (typeId, handlerProcName) pairs for the aggregate provider.

var gApiEventCleanupProcNames* {.compileTime.}: seq[string] =
  @[] ## Accumulates cleanup proc names for delivery thread teardown.

var gApiCppClassMethods* {.compileTime.}: seq[string] =
  @[] ## Accumulates C++ wrapper class method declarations.

# ---------------------------------------------------------------------------
# Compile-time FFI struct registry (for seq[T] support)
# ---------------------------------------------------------------------------

var gApiFfiStructs* {.compileTime.}: seq[(string, seq[(string, string)])] = @[]
  ## Maps ApiType name → [(fieldName, nimTypeName)].
  ## Populated by the `ApiType` macro, consumed by `RequestBroker(API)` for `seq[T]` fields.

proc registerApiFfiStruct*(
    typeName: string, fields: seq[(string, string)]
) {.compileTime.} =
  gApiFfiStructs.add((typeName, fields))

proc lookupFfiStruct*(typeName: string): seq[(string, string)] {.compileTime.} =
  for (name, fields) in gApiFfiStructs:
    if name == typeName:
      return fields
  error(
    "ApiType '" & typeName & "' not registered. " &
      "Declare it with `ApiType:` before using `seq[" & typeName & "]`."
  )

proc appendHeaderDecl*(decl: string) {.compileTime.} =
  gApiHeaderDeclarations.add(decl)

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

proc generateCStruct*(
    structName: string, fields: seq[(string, string)]
): string {.compileTime.} =
  ## Generates a C struct definition string.
  result = "typedef struct {\n"
  for (fieldName, fieldType) in fields:
    if fieldType.endsWith("*"):
      result.add("    " & fieldType & " " & fieldName & ";\n")
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
      if paramType.endsWith("*"):
        result.add(paramType & " " & paramName)
      else:
        result.add(paramType & " " & paramName)
  result.add(");\n")

proc detectOutputDir*(overrideOutDir = ""): string {.compileTime.} =
  ## Resolves the compiler output directory for generated artifacts.
  ## Preference order:
  ## 1. Explicit override define supplied by the caller
  ## 2. Compiler `--outdir`
  ## 3. Directory portion of compiler `--out`
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

proc generateHeaderFile*(outDir: string) {.compileTime.} =
  ## Writes the accumulated C header file.
  ## Includes C++ wrapper class when gApiCppClassMethods has entries.
  let libName = if gApiLibraryName.len > 0: gApiLibraryName else: "brokers_api"
  let guardName = libName.toUpperAscii().replace("-", "_") & "_H"
  let headerPath =
    if outDir.len > 0:
      outDir & "/" & libName & ".h"
    else:
      libName & ".h"
  var header = "#ifndef " & guardName & "\n"
  header.add("#define " & guardName & "\n\n")
  header.add("#include <stdint.h>\n")
  header.add("#include <stdbool.h>\n")
  header.add("#include <stddef.h>\n\n")
  header.add("#ifdef __cplusplus\nextern \"C\" {\n#endif\n\n")
  for decl in gApiHeaderDeclarations:
    header.add(decl)
    header.add("\n")
  header.add("\n#ifdef __cplusplus\n}\n#endif\n\n")

  # C++ wrapper class (header-only, inline)
  if gApiCppClassMethods.len > 0:
    # Derive class name from library name (e.g. "mylib" → "MyLib")
    var className = ""
    var capitalize = true
    for ch in libName:
      if ch == '_' or ch == '-':
        capitalize = true
      elif capitalize:
        className.add(chr(ord(ch) - 32 * ord(ch in {'a' .. 'z'})))
        capitalize = false
      else:
        className.add(ch)

    header.add("#ifdef __cplusplus\n")
    header.add("class " & className & " {\n")
    header.add("    uint32_t ctx_;\n")
    header.add("public:\n")
    header.add("    " & className & "() : ctx_(0) {}\n")
    header.add("    ~" & className & "() { if (ctx_) shutdown(); }\n")
    header.add("    static void initialize() { " & libName & "_initialize(); }\n")
    header.add("    bool init() { ctx_ = " & libName & "_init(); return ctx_ != 0; }\n")
    header.add(
      "    void shutdown() { if (ctx_) { " & libName & "_shutdown(ctx_); ctx_ = 0; } }\n"
    )
    header.add("    void freeString(char* s) { " & libName & "_free_string(s); }\n")
    header.add("    uint32_t ctx() const { return ctx_; }\n")
    for cppMethod in gApiCppClassMethods:
      header.add("    " & cppMethod & "\n")
    header.add("};\n")
    header.add("#endif\n\n")

  header.add("#endif /* " & guardName & " */\n")
  writeFile(headerPath, header)

{.push raises: [].}

# ---------------------------------------------------------------------------
# Runtime memory helpers
# ---------------------------------------------------------------------------

proc allocCStringCopy*(s: string): cstring =
  ## Allocates a copy of a Nim string as a C string.
  ## The caller (C side) is responsible for freeing via the library's
  ## free_string function.
  if s.len == 0:
    return nil
  let buf = cast[cstring](alloc(s.len + 1))
  copyMem(buf, unsafeAddr s[0], s.len)
  cast[ptr char](cast[int](buf) + s.len)[] = '\0'
  buf

proc freeCString*(s: cstring) =
  ## Frees a C string previously allocated by allocCStringCopy.
  if not s.isNil:
    dealloc(s)

# ---------------------------------------------------------------------------
# Shared-memory string helpers for cross-thread event data
# ---------------------------------------------------------------------------
# Under --mm:refc, `alloc`/`dealloc` use per-thread allocators. Event data
# on the delivery thread is allocated and freed there, but these helpers
# use `allocShared`/`deallocShared` for maximum safety across all MM modes.

proc allocSharedCString*(s: string): cstring =
  ## Allocate a C string copy in shared memory (safe for cross-thread use).
  if s.len == 0:
    return nil
  let buf = cast[cstring](allocShared(s.len + 1))
  copyMem(buf, unsafeAddr s[0], s.len)
  cast[ptr char](cast[int](buf) + s.len)[] = '\0'
  buf

proc freeSharedCString*(s: cstring) =
  ## Free a C string allocated by `allocSharedCString`.
  if not s.isNil:
    deallocShared(s)

{.pop.}
