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

var gApiCppStructs* {.compileTime.}: seq[string] =
  @[] ## Accumulates C++ struct definitions (emitted before the class).

var gApiCppPrivateMembers* {.compileTime.}: seq[string] =
  @[] ## Accumulates C++ private static members (trampolines, storage).

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
    of "int", "int8", "int16", "int32", "int64",
       "uint", "uint8", "uint16", "uint32", "uint64":
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
    of "int", "int8", "int16", "int32", "int64",
       "uint", "uint8", "uint16", "uint32", "uint64":
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
    if isSeqType(nimType):
      "field(default_factory=list)"
    else:
      "None"
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

    # C++ standard includes
    header.add("#include <string>\n")
    header.add("#include <string_view>\n")
    header.add("#include <vector>\n")
    header.add("#include <span>\n")
    header.add("#include <functional>\n")
    header.add("#include <optional>\n")
    header.add("#include <mutex>\n")
    header.add("#include <unordered_map>\n")
    header.add("#include <cstring>\n")
    header.add("#include <atomic>\n\n")

    # Derive namespace from library name (lowercase)
    let nsName = libName.toLowerAscii().replace("-", "_")

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

    # C++ structs (ApiType structs, then RequestBroker result structs)
    for s in gApiCppStructs:
      header.add(s)
      header.add("\n")

    header.add("} // namespace " & nsName & "\n\n")

    # Class definition (outside namespace)
    header.add("class " & className & " {\n")
    header.add("    uint32_t ctx_;\n\n")

    # Private members (trampolines, callback storage)
    if gApiCppPrivateMembers.len > 0:
      for m in gApiCppPrivateMembers:
        header.add(m & "\n")
      header.add("\n")

    header.add("public:\n")
    header.add("    " & className & "() : ctx_(0) {}\n")
    header.add("    ~" & className & "() { if (ctx_) shutdown(); }\n")
    header.add("    " & className & "(const " & className & "&) = delete;\n")
    header.add("    " & className & "& operator=(const " & className & "&) = delete;\n")
    header.add("    " & className & "(" & className & "&&) = delete;\n")
    header.add("    " & className & "& operator=(" & className & "&&) = delete;\n\n")
    header.add("    static void initialize() { " & libName & "_initialize(); }\n")
    header.add("    bool init() { ctx_ = " & libName & "_init(); return ctx_ != 0; }\n")
    header.add(
      "    void shutdown() { if (ctx_) { " & libName & "_shutdown(ctx_); ctx_ = 0; } }\n"
    )
    header.add("    uint32_t ctx() const { return ctx_; }\n\n")
    for cppMethod in gApiCppClassMethods:
      header.add("    " & cppMethod.replace("__CPP_NS__", nsName) & "\n")
    header.add("};\n\n")
    header.add("#endif /* __cplusplus */\n\n")

  header.add("#endif /* " & guardName & " */\n")
  writeFile(headerPath, header)

proc generatePythonFile*(outDir: string) {.compileTime.} =
  ## Writes the accumulated Python wrapper file.
  ## Generates a single .py module with ctypes bindings, dataclasses,
  ## and a Pythonic wrapper class mirroring the C++ class experience.
  let libName = if gApiLibraryName.len > 0: gApiLibraryName else: "brokers_api"
  let pyPath =
    if outDir.len > 0:
      outDir & "/" & libName & ".py"
    else:
      libName & ".py"

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
  py.add("\nGenerated from Nim macros. Do not edit manually.\n"
  )
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
  py.add("# ---------------------------------------------------------------------------\n")
  py.add("# Library loader\n")
  py.add("# ---------------------------------------------------------------------------\n\n")
  py.add("def _load_library(name: str = \"" & libName & "\") -> ctypes.CDLL:\n")
  py.add("    \"\"\"Load the shared library, searching relative to this file first.\"\"\"\n")
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
  py.add("# ---------------------------------------------------------------------------\n")
  py.add("# Error type\n")
  py.add("# ---------------------------------------------------------------------------\n\n")
  py.add("class " & className & "Error(Exception):\n")
  py.add("    \"\"\"Raised when a library call returns an error.\"\"\"\n")
  py.add("    pass\n\n")

  # ctypes Structure definitions
  py.add("# ---------------------------------------------------------------------------\n")
  py.add("# ctypes structures\n")
  py.add("# ---------------------------------------------------------------------------\n\n")
  for s in gApiPyCtypesStructs:
    py.add(s)
    py.add("\n\n")

  # Python dataclass definitions
  py.add("# ---------------------------------------------------------------------------\n")
  py.add("# Dataclasses\n")
  py.add("# ---------------------------------------------------------------------------\n\n")
  for d in gApiPyDataclasses:
    py.add(d)
    py.add("\n\n")

  # Wrapper class
  py.add("# ---------------------------------------------------------------------------\n")
  py.add("# Wrapper class\n")
  py.add("# ---------------------------------------------------------------------------\n\n")
  py.add("class " & className & ":\n")
  py.add("    \"\"\"Pythonic wrapper around the " & libName & " shared library.\n\n")
  py.add("    Usage::\n\n")
  py.add("        with " & className & "() as lib:\n")
  py.add("            result = lib.init_request(\"/path/to/config\")\n")
  py.add("            print(result.config_path)\n")
  py.add("    \"\"\"\n\n")

  # __init__
  py.add("    def __init__(self, lib_path: Optional[str] = None) -> None:\n")
  py.add("        self._lib = _load_library(lib_path) if lib_path else _load_library()\n")
  py.add("        self._ctx: int = 0\n")
  py.add("        self._cb_refs: dict[int, ctypes._CFuncPtr] = {}  # prevent GC\n")
  py.add("        self._lock = threading.Lock()\n")
  py.add("        self._setup_signatures()\n")
  py.add("        self._lib." & libName & "_initialize()\n")
  py.add("        self._ctx = self._lib." & libName & "_init()\n")
  py.add("        if self._ctx == 0:\n")
  py.add("            raise " & className & "Error(\"Library initialization failed\")\n\n")

  # _setup_signatures
  py.add("    def _setup_signatures(self) -> None:\n")
  py.add("        \"\"\"Configure ctypes argtypes/restype for all C functions.\"\"\"\n")
  py.add("        _lib = self._lib\n")
  # Lifecycle functions
  py.add("        _lib." & libName & "_initialize.argtypes = []\n")
  py.add("        _lib." & libName & "_initialize.restype = None\n")
  py.add("        _lib." & libName & "_init.argtypes = []\n")
  py.add("        _lib." & libName & "_init.restype = ctypes.c_uint32\n")
  py.add("        _lib." & libName & "_shutdown.argtypes = [ctypes.c_uint32]\n")
  py.add("        _lib." & libName & "_shutdown.restype = None\n")
  for setup in gApiPyCallbackSetup:
    py.add("        " & setup & "\n")
  py.add("\n")

  # Context manager
  py.add("    def __enter__(self) -> " & className & ":\n")
  py.add("        return self\n\n")
  py.add("    def __exit__(self, *_: object) -> None:\n")
  py.add("        self.shutdown()\n\n")

  # shutdown
  py.add("    def shutdown(self) -> None:\n")
  py.add("        \"\"\"Shut down the library context. Safe to call multiple times.\"\"\"\n")
  py.add("        if self._ctx:\n")
  py.add("            self._lib." & libName & "_shutdown(self._ctx)\n")
  py.add("            self._ctx = 0\n")
  py.add("            self._cb_refs.clear()\n\n")

  # __del__
  py.add("    def __del__(self) -> None:\n")
  py.add("        self.shutdown()\n\n")

  # ctx property
  py.add("    @property\n")
  py.add("    def ctx(self) -> int:\n")
  py.add("        \"\"\"The raw library context handle.\"\"\"\n")
  py.add("        return self._ctx\n\n")

  # Request methods
  let pyErrClass = className & "Error"
  for m in gApiPyMethods:
    py.add(m.replace("__LIB_ERROR__", pyErrClass))
    py.add("\n\n")

  # Event methods
  for m in gApiPyEventMethods:
    py.add(m.replace("__LIB_ERROR__", pyErrClass))
    py.add("\n\n")

  writeFile(pyPath, py)

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
