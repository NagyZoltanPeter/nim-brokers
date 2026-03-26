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

var gApiRequestCleanupProcNames* {.compileTime.}: seq[string] =
  @[] ## Accumulates cleanup proc names for request provider teardown.

var gApiCppClassMethods* {.compileTime.}: seq[string] =
  @[] ## Accumulates C++ wrapper class method declarations.

var gApiCppInterfaceSummary* {.compileTime.}: seq[string] =
  @[] ## Accumulates dense, type-free C++ wrapper interface summary lines.

var gApiCppPreamble* {.compileTime.}: seq[string] =
  @[] ## Accumulates reusable C++ helper templates and event traits.

var gApiCppStructs* {.compileTime.}: seq[string] =
  @[] ## Accumulates C++ struct definitions (emitted before the class).

var gApiCppPrivateMembers* {.compileTime.}: seq[string] =
  @[] ## Accumulates C++ private members and aliases.

var gApiCppConstructorInitializers* {.compileTime.}: seq[string] =
  @[] ## Accumulates C++ wrapper constructor initializer fragments.

var gApiCppShutdownStatements* {.compileTime.}: seq[string] =
  @[] ## Accumulates C++ wrapper shutdown cleanup statements.

var gApiCppEventSupportGenerated* {.compileTime.}: bool = false
  ## Flag: has the shared C++ EventDispatcher template been emitted?

# ---------------------------------------------------------------------------
# Compile-time accumulators for Python wrapper generation
# ---------------------------------------------------------------------------

var gApiPyCtypesStructs* {.compileTime.}: seq[string] =
  @[] ## ctypes.Structure subclass definitions (CItem + CResult types).

var gApiPyDataclasses* {.compileTime.}: seq[string] =
  @[] ## Python dataclass definitions (high-level result/item types).

var gApiPyMethods* {.compileTime.}: seq[string] =
  @[] ## Python wrapper class method definitions.

var gApiPyEventMethods* {.compileTime.}: seq[string] =
  @[] ## Python wrapper class on/off event method definitions.

var gApiPyInterfaceSummary* {.compileTime.}: seq[string] =
  @[] ## Accumulates dense, type-free Python wrapper interface summary lines.

var gApiPyCallbackSetup* {.compileTime.}: seq[string] =
  @[] ## Python CFUNCTYPE definitions and argtypes/restype setup lines.

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

proc apiPublicCName*(suffix: string): string {.compileTime.} =
  ApiLibPrefixPlaceholder & suffix

proc registerApiCExportWrapper*(
    publicSuffix: string,
    rawName: string,
    returnType: string,
    params: seq[(string, string)],
) {.compileTime.} =
  gApiCExportWrappers.add((publicSuffix, rawName, returnType, params))

# ---------------------------------------------------------------------------
# Compile-time C++ type mapping
# ---------------------------------------------------------------------------

proc nimTypeToCpp*(nimType: NimNode): string {.compileTime.} =
  ## Maps a Nim type to its C++ equivalent for struct fields / return types.
  ## string → std::string, seq[T] → std::vector<T>, primitives pass through.
  case nimType.kind
  of nnkIdent:
    let name = ($nimType).toLowerAscii()
    case name
    of "string", "cstring":
      "std::string"
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
    of "brokercontext":
      "uint32_t"
    of "pointer":
      "void*"
    else:
      $nimType # user-defined C++ struct name
  of nnkBracketExpr:
    if isSeqType(nimType):
      "std::vector<" & seqItemTypeName(nimType) & ">"
    else:
      error("Generic types other than seq[T] not supported for C++ mapping", nimType)
  else:
    error("Unsupported type node for C++ mapping: " & $nimType.kind, nimType)

proc nimTypeToCppParam*(nimType: NimNode): string {.compileTime.} =
  ## Maps a Nim type to a C++ method input parameter type.
  ## string → const std::string&, primitives pass through.
  let cppType = nimTypeToCpp(nimType)
  if cppType == "std::string":
    "const std::string&"
  elif cppType.startsWith("std::vector<"):
    "const " & cppType & "&"
  else:
    cppType

proc nimTypeToCppCallbackParam*(nimType: NimNode): string {.compileTime.} =
  ## Maps a Nim type to the C++ callback parameter type.
  ## string → std::string_view, seq[T] → std::span<const T>, primitives pass through.
  case nimType.kind
  of nnkIdent:
    let name = ($nimType).toLowerAscii()
    if name in ["string", "cstring"]:
      "const std::string_view"
    else:
      nimTypeToCpp(nimType)
  of nnkBracketExpr:
    if isSeqType(nimType):
      "std::span<const " & seqItemTypeName(nimType) & ">"
    else:
      nimTypeToCpp(nimType)
  else:
    nimTypeToCpp(nimType)

# ---------------------------------------------------------------------------
# Compile-time Python type mapping
# ---------------------------------------------------------------------------

proc nimTypeToCtypes*(nimType: NimNode): string {.compileTime.} =
  ## Maps a Nim type to its ctypes equivalent for Structure field definitions.
  case nimType.kind
  of nnkIdent:
    let name = ($nimType).toLowerAscii()
    case name
    of "int", "int32":
      "ctypes.c_int32"
    of "int8":
      "ctypes.c_int8"
    of "int16":
      "ctypes.c_int16"
    of "int64":
      "ctypes.c_int64"
    of "uint", "uint32":
      "ctypes.c_uint32"
    of "uint8":
      "ctypes.c_uint8"
    of "uint16":
      "ctypes.c_uint16"
    of "uint64":
      "ctypes.c_uint64"
    of "float", "float64":
      "ctypes.c_double"
    of "float32":
      "ctypes.c_float"
    of "bool":
      "ctypes.c_bool"
    of "string", "cstring":
      "ctypes.c_char_p"
    of "brokercontext":
      "ctypes.c_uint32"
    of "pointer":
      "ctypes.c_void_p"
    else:
      $nimType & "CItem" # user-defined ctypes Structure
  of nnkBracketExpr:
    if isSeqType(nimType):
      "ctypes.c_void_p" # pointer to array
    else:
      "ctypes.c_void_p"
  else:
    "ctypes.c_void_p"

proc nimTypeToPyAnnotation*(nimType: NimNode): string {.compileTime.} =
  ## Maps a Nim type to a Python type annotation for dataclass fields.
  case nimType.kind
  of nnkIdent:
    let name = ($nimType).toLowerAscii()
    case name
    of "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32",
        "uint64":
      "int"
    of "float", "float32", "float64":
      "float"
    of "bool":
      "bool"
    of "string", "cstring":
      "str"
    else:
      $nimType # user-defined dataclass name
  of nnkBracketExpr:
    if isSeqType(nimType):
      "list[" & seqItemTypeName(nimType) & "]"
    else:
      "object"
  else:
    "object"

proc nimTypeToPyDefault*(nimType: NimNode): string {.compileTime.} =
  ## Returns a Python default value for a dataclass field.
  case nimType.kind
  of nnkIdent:
    let name = ($nimType).toLowerAscii()
    case name
    of "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32",
        "uint64":
      "0"
    of "float", "float32", "float64":
      "0.0"
    of "bool":
      "False"
    of "string", "cstring":
      "\"\""
    else:
      "None"
  of nnkBracketExpr:
    if isSeqType(nimType): "field(default_factory=list)" else: "None"
  else:
    "None"

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

proc generateHeaderFile*(outDir: string) {.compileTime, raises: [].} =
  ## Writes the accumulated C header file.
  ## Includes C++ wrapper class when gApiCppClassMethods has entries.
  ensureGeneratedOutputDir(outDir)
  let libName = if gApiLibraryName.len > 0: gApiLibraryName else: "brokers_api"
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

  # Modern C++ section (header-only, inline)
  if gApiCppClassMethods.len > 0:
    # Derive class name from library name (e.g. "mylib" → "Mylib")
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

    header.add("#ifdef __cplusplus\n\n")

    header.add("// Quick C++ wrapper interface summary (names only)\n")
    header.add("// class " & className & " {\n")
    header.add("// public:\n")
    for summaryLine in [
      "createContext();", "validContext() const;", "operator bool() const;",
      "shutdown();", "ctx() const;",
    ]:
      header.add("//   " & summaryLine & "\n")
    for summaryLine in gApiCppInterfaceSummary:
      header.add("//   " & summaryLine & "\n")
    header.add("// };\n\n")

    # C++ standard includes
    header.add("#include <string>\n")
    header.add("#include <string_view>\n")
    header.add("#include <vector>\n")
    header.add("#include <span>\n")
    header.add("#include <functional>\n")
    header.add("#include <optional>\n")
    header.add("#include <mutex>\n")
    header.add("#include <unordered_map>\n")
    header.add("#include <utility>\n")
    header.add("#include <cstring>\n")
    header.add("#include <atomic>\n\n")

    # Derive namespace from library name (lowercase)
    let nsName = libName.toLowerAscii().replace("-", "_")
    let createContextResultName = className & "CreateContextResult"

    header.add("namespace " & nsName & " {\n\n")

    # Result<T> template
    header.add("// Result<T> — mirrors Nim's Result[T, string]\n")
    header.add("template <typename T>\n")
    header.add("class Result {\n")
    header.add("    std::optional<T> value_;\n")
    header.add("    std::string error_;\n")
    header.add("public:\n")
    header.add("    Result(T val) : value_(std::move(val)) {}\n")
    header.add("    Result(std::string err) : error_(std::move(err)) {}\n")
    header.add("    bool ok() const { return value_.has_value(); }\n")
    header.add("    explicit operator bool() const { return ok(); }\n")
    header.add("    const T& value() const { return *value_; }\n")
    header.add("    T& value() { return *value_; }\n")
    header.add("    const T& operator*() const { return *value_; }\n")
    header.add("    const T* operator->() const { return &*value_; }\n")
    header.add("    const std::string& error() const { return error_; }\n")
    header.add("};\n\n")

    header.add("template <>\n")
    header.add("class Result<void> {\n")
    header.add("    bool ok_ = true;\n")
    header.add("    std::string error_;\n")
    header.add("public:\n")
    header.add("    Result() = default;\n")
    header.add("    Result(std::string err) : ok_(false), error_(std::move(err)) {}\n")
    header.add("    bool ok() const { return ok_; }\n")
    header.add("    explicit operator bool() const { return ok(); }\n")
    header.add("    const std::string& error() const { return error_; }\n")
    header.add("};\n\n")

    # C++ structs (ApiType structs, then RequestBroker result structs)
    for s in gApiCppStructs:
      header.add(s.replace(ApiLibPrefixPlaceholder, apiPrefix))
      header.add("\n")

    header.add("struct " & createContextResultName & " {\n")
    header.add("    uint32_t ctx = 0;\n")
    header.add("    " & createContextResultName & "() = default;\n")
    header.add(
      "    explicit " & createContextResultName & "(" & libName &
        "CreateContextResult& c)\n"
    )
    header.add("        : ctx(c.ctx) {\n")
    header.add("        " & "free_" & libName & "_create_context_result(&c);\n")
    header.add("    }\n")
    header.add("};\n\n")

    header.add("} // namespace " & nsName & "\n\n")

    for p in gApiCppPreamble:
      header.add(
        p.replace("__CPP_NS__", nsName).replace("__CPP_CLASS__", className).replace(
          ApiLibPrefixPlaceholder, apiPrefix
        ) & "\n"
      )
    if gApiCppPreamble.len > 0:
      header.add("\n")

    # Class definition (outside namespace)
    header.add("class " & className & " {\n")
    header.add("protected:\n")
    header.add("    uint32_t ctx_;\n\n")

    header.add("private:\n")

    # Private members and aliases
    if gApiCppPrivateMembers.len > 0:
      for m in gApiCppPrivateMembers:
        header.add(
          m.replace("__CPP_NS__", nsName).replace("__CPP_CLASS__", className).replace(
            ApiLibPrefixPlaceholder, apiPrefix
          ) & "\n"
        )
      header.add("\n")

    header.add("public:\n")
    var ctorInitializers = @["ctx_(0)"]
    for init in gApiCppConstructorInitializers:
      ctorInitializers.add(init)
    header.add("    " & className & "() : " & ctorInitializers.join(", ") & " {}\n")
    header.add("    virtual ~" & className & "() { shutdown(); }\n")
    header.add("    " & className & "(const " & className & "&) = delete;\n")
    header.add("    " & className & "& operator=(const " & className & "&) = delete;\n")
    header.add("    " & className & "(" & className & "&&) = delete;\n")
    header.add("    " & className & "& operator=(" & className & "&&) = delete;\n\n")
    header.add("    " & nsName & "::Result<void> createContext() {\n")
    header.add("        if (ctx_)\n")
    header.add(
      "            return " & nsName &
        "::Result<void>(std::string(\"Context already created\"));\n"
    )
    header.add("        auto c = " & libName & "_createContext();\n")
    header.add("        if (c.error_message) {\n")
    header.add("            std::string err(c.error_message);\n")
    header.add("            " & "free_" & libName & "_create_context_result(&c);\n")
    header.add("            return " & nsName & "::Result<void>(std::move(err));\n")
    header.add("        }\n")
    header.add("        ctx_ = c.ctx;\n")
    header.add("        " & "free_" & libName & "_create_context_result(&c);\n")
    header.add("        if (!ctx_)\n")
    header.add(
      "            return " & nsName &
        "::Result<void>(std::string(\"createContext failed\"));\n"
    )
    header.add("        return " & nsName & "::Result<void>();\n")
    header.add("    }\n")
    header.add("    bool validContext() const noexcept { return ctx_ != 0; }\n")
    header.add(
      "    explicit operator bool() const noexcept { return validContext(); }\n"
    )
    header.add("    void shutdown() noexcept {\n")
    for stmt in gApiCppShutdownStatements:
      header.add(
        "        " &
          stmt.replace("__CPP_NS__", nsName).replace("__CPP_CLASS__", className).replace(
            ApiLibPrefixPlaceholder, apiPrefix
          ) & "\n"
      )
    header.add("        if (ctx_) { " & libName & "_shutdown(ctx_); ctx_ = 0; }\n")
    header.add("    }\n")
    header.add("    uint32_t ctx() const noexcept { return ctx_; }\n\n")
    for cppMethod in gApiCppClassMethods:
      header.add(
        "    " &
          cppMethod
          .replace("__CPP_NS__", nsName)
          .replace("__CPP_CLASS__", className)
          .replace(ApiLibPrefixPlaceholder, apiPrefix) & "\n"
      )
    header.add("};\n\n")
    header.add("#endif /* __cplusplus */\n\n")

  header.add("#endif /* " & guardName & " */\n")
  try:
    writeFile(headerPath, header)
  except IOError:
    error(
      "Failed to write generated header file '" & headerPath & "': " &
        getCurrentExceptionMsg()
    )

proc generatePythonFile*(outDir: string) {.compileTime, raises: [].} =
  ## Writes the accumulated Python wrapper file.
  ## Generates a single .py module with ctypes bindings, dataclasses,
  ## and a Pythonic wrapper class mirroring the C++ class experience.
  ensureGeneratedOutputDir(outDir)
  let libName = if gApiLibraryName.len > 0: gApiLibraryName else: "brokers_api"
  let pyPath =
    if outDir.len > 0:
      outDir & "/" & libName & ".py"
    else:
      libName & ".py"
  let apiPrefix = libName & "_"

  # Derive class name from library name (PascalCase)
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

  var py = "\"\"\"" & className & " — Python wrapper (auto-generated)\n"
  py.add("\nGenerated from Nim macros. Do not edit manually.\n")
  py.add("\"\"\"\n\n")
  py.add("from __future__ import annotations\n\n")
  py.add("import ctypes\n")
  py.add("import ctypes.util\n")
  py.add("import os\n")
  py.add("import sys\n")
  py.add("import threading\n")
  py.add("from dataclasses import dataclass, field\n")
  py.add("from pathlib import Path\n")
  py.add("from typing import Callable, Optional\n\n")

  # Library loader
  py.add(
    "# ---------------------------------------------------------------------------\n"
  )
  py.add("# Library loader\n")
  py.add(
    "# ---------------------------------------------------------------------------\n\n"
  )
  py.add("def _load_library(name: str = \"" & libName & "\") -> ctypes.CDLL:\n")
  py.add(
    "    \"\"\"Load the shared library, searching relative to this file first.\"\"\"\n"
  )
  py.add("    here = Path(__file__).parent\n")
  py.add("    if sys.platform == \"darwin\":\n")
  py.add("        suffix = \".dylib\"\n")
  py.add("    elif sys.platform == \"win32\":\n")
  py.add("        suffix = \".dll\"\n")
  py.add("    else:\n")
  py.add("        suffix = \".so\"\n")
  py.add("    # Try relative paths first\n")
  py.add("    for candidate in [\n")
  py.add("        here / f\"lib{name}{suffix}\",\n")
  py.add("        here / f\"{name}{suffix}\",\n")
  py.add("    ]:\n")
  py.add("        if candidate.exists():\n")
  py.add("            return ctypes.CDLL(str(candidate))\n")
  py.add("    # Fall back to system search\n")
  py.add("    path = ctypes.util.find_library(name)\n")
  py.add("    if path:\n")
  py.add("        return ctypes.CDLL(path)\n")
  py.add("    raise OSError(f\"Cannot find shared library '{name}'\")\n\n")

  # Error class
  py.add(
    "# ---------------------------------------------------------------------------\n"
  )
  py.add("# Error type\n")
  py.add(
    "# ---------------------------------------------------------------------------\n\n"
  )
  py.add("class " & className & "Error(Exception):\n")
  py.add("    \"\"\"Raised when a library call returns an error.\"\"\"\n")
  py.add("    pass\n\n")

  # ctypes Structure definitions
  py.add(
    "# ---------------------------------------------------------------------------\n"
  )
  py.add("# ctypes structures\n")
  py.add(
    "# ---------------------------------------------------------------------------\n\n"
  )
  let pyCreateContextResultName = className & "CreateContextResult"
  let freeCreateContextResultFuncName = "free_" & libName & "_create_context_result"
  py.add("class " & pyCreateContextResultName & "(ctypes.Structure):\n")
  py.add("    _fields_ = [\n")
  py.add("        (\"ctx\", ctypes.c_uint32),\n")
  py.add("        (\"error_message\", ctypes.c_char_p),\n")
  py.add("    ]\n\n")

  for s in gApiPyCtypesStructs:
    py.add(s)
    py.add("\n\n")

  # Python dataclass definitions
  py.add(
    "# ---------------------------------------------------------------------------\n"
  )
  py.add("# Dataclasses\n")
  py.add(
    "# ---------------------------------------------------------------------------\n\n"
  )
  for d in gApiPyDataclasses:
    py.add(d)
    py.add("\n\n")

  # Wrapper class
  py.add(
    "# ---------------------------------------------------------------------------\n"
  )
  py.add("# Wrapper class\n")
  py.add(
    "# ---------------------------------------------------------------------------\n\n"
  )
  py.add("# Quick Python wrapper interface summary (names only)\n")
  py.add("# class " & className & ":\n")
  for summaryLine in [
    "__enter__()", "__exit__()", "createContext()", "create_context()",
    "validContext()", "valid_context()", "__bool__()", "shutdown()", "ctx",
  ]:
    py.add("#   " & summaryLine & "\n")
  for summaryLine in gApiPyInterfaceSummary:
    py.add("#   " & summaryLine & "\n")
  py.add("\n")
  py.add("class " & className & ":\n")
  py.add("    \"\"\"Pythonic wrapper around the " & libName & " shared library.\n\n")
  py.add("    Usage::\n\n")
  py.add("        with " & className & "() as lib:\n")
  py.add("            lib.createContext()\n")
  py.add("            result = lib.initializeRequest(\"/path/to/config\")\n")
  py.add("            print(result.configPath)\n")
  py.add("    \"\"\"\n\n")

  # __init__
  py.add("    def __init__(self, lib_path: Optional[str] = None) -> None:\n")
  py.add(
    "        self._lib = _load_library(lib_path) if lib_path else _load_library()\n"
  )
  py.add("        self._ctx: int = 0\n")
  py.add(
    "        self._cb_refs: dict[tuple[str, int], ctypes._CFuncPtr] = {}  # prevent GC\n"
  )
  py.add("        self._lock = threading.Lock()\n")
  py.add("        self._setup_signatures()\n\n")

  # _setup_signatures
  py.add("    def _setup_signatures(self) -> None:\n")
  py.add("        \"\"\"Configure ctypes argtypes/restype for all C functions.\"\"\"\n")
  py.add("        _lib = self._lib\n")
  # Lifecycle functions
  py.add("        _lib." & libName & "_createContext.argtypes = []\n")
  py.add(
    "        _lib." & libName & "_createContext.restype = " & pyCreateContextResultName &
      "\n"
  )
  py.add(
    "        _lib." & freeCreateContextResultFuncName & ".argtypes = [ctypes.POINTER(" &
      pyCreateContextResultName & ")]\n"
  )
  py.add("        _lib." & freeCreateContextResultFuncName & ".restype = None\n")
  py.add("        _lib." & libName & "_shutdown.argtypes = [ctypes.c_uint32]\n")
  py.add("        _lib." & libName & "_shutdown.restype = None\n")
  for setup in gApiPyCallbackSetup:
    py.add("        " & setup.replace(ApiLibPrefixPlaceholder, apiPrefix) & "\n")
  py.add("\n")

  # Context manager
  py.add("    def __enter__(self) -> " & className & ":\n")
  py.add("        return self\n\n")
  py.add("    def __exit__(self, *_: object) -> None:\n")
  py.add("        self.shutdown()\n\n")

  py.add("    def createContext(self) -> None:\n")
  py.add("        \"\"\"Create the library context explicitly.\"\"\"\n")
  py.add("        if self._ctx != 0:\n")
  py.add("            raise " & className & "Error(\"Context already created\")\n")
  py.add("        c = self._lib." & libName & "_createContext()\n")
  py.add("        try:\n")
  py.add("            if c.error_message:\n")
  py.add(
    "                raise " & className & "Error(c.error_message.decode(\"utf-8\"))\n"
  )
  py.add("            self._ctx = c.ctx\n")
  py.add("            if self._ctx == 0:\n")
  py.add(
    "                raise " & className & "Error(\"Library context creation failed\")\n"
  )
  py.add("        finally:\n")
  py.add(
    "            self._lib." & freeCreateContextResultFuncName & "(ctypes.byref(c))\n\n"
  )

  py.add("    def create_context(self) -> None:\n")
  py.add("        self.createContext()\n\n")

  py.add("    def validContext(self) -> bool:\n")
  py.add("        return self._ctx != 0\n\n")

  py.add("    def valid_context(self) -> bool:\n")
  py.add("        return self.validContext()\n\n")

  py.add("    def __bool__(self) -> bool:\n")
  py.add("        return self.validContext()\n\n")

  py.add("    def _requireContext(self) -> None:\n")
  py.add("        if self._ctx == 0:\n")
  py.add(
    "            raise " & className & "Error(\"Library context is not created\")\n\n"
  )

  # shutdown
  py.add("    def shutdown(self) -> None:\n")
  py.add(
    "        \"\"\"Shut down the library context. Safe to call multiple times.\"\"\"\n"
  )
  py.add("        ctx = getattr(self, \"_ctx\", None)\n")
  py.add("        if ctx:\n")
  py.add("            self._lib." & libName & "_shutdown(ctx)\n")
  py.add("            self._ctx = 0\n")
  py.add("            self._cb_refs.clear()\n\n")

  # __del__
  py.add("    def __del__(self) -> None:\n")
  py.add("        # Defensive: __del__ may run on partially constructed objects\n")
  py.add("        if hasattr(self, \"shutdown\"):\n")
  py.add("            try:\n")
  py.add("                self.shutdown()\n")
  py.add("            except Exception:\n")
  py.add("                pass\n\n")

  # ctx property
  py.add("    @property\n")
  py.add("    def ctx(self) -> int:\n")
  py.add("        \"\"\"The raw library context handle.\"\"\"\n")
  py.add("        return self._ctx\n\n")

  # Request methods
  let pyErrClass = className & "Error"
  for m in gApiPyMethods:
    py.add(
      m.replace("__LIB_ERROR__", pyErrClass).replace(ApiLibPrefixPlaceholder, apiPrefix)
    )
    py.add("\n\n")

  # Event methods
  for m in gApiPyEventMethods:
    py.add(
      m.replace("__LIB_ERROR__", pyErrClass).replace(ApiLibPrefixPlaceholder, apiPrefix)
    )
    py.add("\n\n")

  try:
    writeFile(pyPath, py)
  except IOError:
    error(
      "Failed to write generated Python wrapper '" & pyPath & "': " &
        getCurrentExceptionMsg()
    )

{.push raises: [].}

# ---------------------------------------------------------------------------
# Runtime memory helpers
# ---------------------------------------------------------------------------

proc allocCStringCopy*(s: string): cstring =
  ## Allocates a copy of a Nim string as a shared C string.
  ## The caller frees it via the generated FFI free helpers, which may run on
  ## a different thread than the allocation site under --mm:refc.
  if s.len == 0:
    return nil
  let buf = cast[cstring](allocShared(s.len + 1))
  copyMem(buf, unsafeAddr s[0], s.len)
  cast[ptr char](cast[int](buf) + s.len)[] = '\0'
  buf

proc freeCString*(s: cstring) =
  ## Frees a C string previously allocated by allocCStringCopy.
  if not s.isNil:
    deallocShared(s)

# ---------------------------------------------------------------------------
# Shared-memory string helpers for cross-thread event data
# ---------------------------------------------------------------------------
# Under --mm:refc, `alloc`/`dealloc` use per-thread allocators. Event data
# on the delivery thread is allocated and freed there, but these helpers
# use `allocShared`/`deallocShared` for maximum safety across all MM modes.

proc allocSharedCString*(s: string): cstring =
  ## Allocate a C string copy in shared memory (safe for cross-thread use).
  allocCStringCopy(s)

proc freeSharedCString*(s: cstring) =
  ## Free a C string allocated by `allocSharedCString`.
  freeCString(s)

{.pop.}
