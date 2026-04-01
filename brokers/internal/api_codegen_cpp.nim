## api_codegen_cpp
## ----------------
## C++ wrapper code generation for the FFI API system.
##
## Owns:
## - C++ type mapping procs (Nim → C++ types)
## - Compile-time accumulators for C++ structs, class methods, events
## - `generateCppHeaderFile` — writes the `.hpp` file
##
## The `.hpp` includes the `.h` (pure C) and adds the C++ namespace,
## Result template, RAII structs, EventDispatcher, and wrapper class.

{.push raises: [].}

import std/[macros, os, strutils]
import ./api_codegen_c
import ./api_schema

export api_codegen_c
export api_schema

# ---------------------------------------------------------------------------
# Compile-time C++ type mapping
# ---------------------------------------------------------------------------

proc nimTypeToCpp*(nimType: NimNode): string {.compileTime.} =
  ## Maps a Nim type to its C++ equivalent.
  ## string → std::string, seq[T] → std::vector<T>, array[N,T] → std::array<T,N>,
  ## primitives pass through.
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
    of "byte":
      "uint8_t"
    else:
      if isAliasOrDistinctRegistered($nimType):
        nimTypeToCpp(ident(resolveUnderlyingType($nimType)))
      else:
        $nimType # enum typedef or user-defined struct name
  of nnkBracketExpr:
    if isSeqType(nimType):
      let elemName = seqItemTypeName(nimType)
      if isNimPrimitive(elemName):
        "std::vector<" & nimTypeToCpp(ident(elemName)) & ">"
      else:
        "std::vector<" & elemName & ">"
    elif isArrayTypeNode(nimType):
      let n = arrayNodeSize(nimType)
      let elemName = arrayNodeElemName(nimType)
      "std::array<" & nimTypeToCpp(ident(elemName)) & ", " & $n & ">"
    else:
      error(
        "Generic types other than seq[T] and array[N,T] not supported for C++ mapping",
        nimType,
      )
  else:
    error("Unsupported type node for C++ mapping: " & $nimType.kind, nimType)

proc nimTypeToCppParam*(nimType: NimNode): string {.compileTime.} =
  ## Maps a Nim type to a C++ method input parameter type.
  ## string → const std::string&, vector/array → const T&, primitives pass through.
  let cppType = nimTypeToCpp(nimType)
  if cppType == "std::string":
    "const std::string&"
  elif cppType.startsWith("std::vector<") or cppType.startsWith("std::array<"):
    "const " & cppType & "&"
  else:
    cppType

proc nimTypeToCppCallbackParam*(nimType: NimNode): string {.compileTime.} =
  ## Maps a Nim type to the C++ callback parameter type.
  ## string → std::string_view, seq[T] → std::span<const T>,
  ## array[N,T] → std::span<const T> (flattened for callbacks).
  case nimType.kind
  of nnkIdent:
    let name = ($nimType).toLowerAscii()
    if name in ["string", "cstring"]:
      "const std::string_view"
    else:
      nimTypeToCpp(nimType)
  of nnkBracketExpr:
    if isSeqType(nimType):
      let elemName = seqItemTypeName(nimType)
      if isNimPrimitive(elemName):
        "std::span<const " & nimTypeToCpp(ident(elemName)) & ">"
      else:
        "std::span<const " & elemName & ">"
    elif isArrayTypeNode(nimType):
      let elemName = arrayNodeElemName(nimType)
      if isNimPrimitive(elemName):
        "std::span<const " & nimTypeToCpp(ident(elemName)) & ">"
      else:
        "std::span<const " & elemName & ">"
    else:
      nimTypeToCpp(nimType)
  else:
    nimTypeToCpp(nimType)

# ---------------------------------------------------------------------------
# Compile-time accumulators
# ---------------------------------------------------------------------------

var gApiCppClassMethods* {.compileTime.}: seq[string] =
  @[] ## C++ wrapper class method declarations.

var gApiCppInterfaceSummary* {.compileTime.}: seq[string] =
  @[] ## Dense, type-free C++ wrapper interface summary lines.

var gApiCppPreamble* {.compileTime.}: seq[string] =
  @[] ## Reusable C++ helper templates and event traits.

var gApiCppStructs* {.compileTime.}: seq[string] =
  @[] ## C++ struct definitions (emitted before the class).

var gApiCppPrivateMembers* {.compileTime.}: seq[string] =
  @[] ## C++ private members and aliases.

var gApiCppConstructorInitializers* {.compileTime.}: seq[string] =
  @[] ## C++ wrapper constructor initializer fragments.

var gApiCppShutdownStatements* {.compileTime.}: seq[string] =
  @[] ## C++ wrapper shutdown cleanup statements.

var gApiCppEventSupportGenerated* {.compileTime.}: bool = false
  ## Flag: has the shared C++ EventDispatcher template been emitted?

# ---------------------------------------------------------------------------
# C++ header file generation
# ---------------------------------------------------------------------------

{.pop.} # temporarily lift raises:[] for compile-time proc using writeFile

proc generateCppHeaderFile*(
    outDir: string, libName: string
) {.compileTime, raises: [].} =
  ## Writes the C++ wrapper header file (.hpp).
  ## Includes the pure C .h and adds the C++ namespace, Result template,
  ## RAII structs, EventDispatcher, and wrapper class.
  if gApiCppClassMethods.len == 0:
    return # No C++ content to generate

  ensureGeneratedOutputDir(outDir)
  let hppPath =
    if outDir.len > 0:
      outDir & "/" & libName & ".hpp"
    else:
      libName & ".hpp"
  let apiPrefix = libName & "_"

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

  let nsName = libName.toLowerAscii().replace("-", "_")
  let createContextResultName = className & "CreateContextResult"

  var hpp = "#pragma once\n\n"
  hpp.add("#include \"" & libName & ".h\"\n\n")

  hpp.add("// Quick C++ wrapper interface summary (names only)\n")
  hpp.add("// class " & className & " {\n")
  hpp.add("// public:\n")
  for summaryLine in [
    "createContext();", "validContext() const;", "operator bool() const;",
    "shutdown();", "ctx() const;",
  ]:
    hpp.add("//   " & summaryLine & "\n")
  for summaryLine in gApiCppInterfaceSummary:
    hpp.add("//   " & summaryLine & "\n")
  hpp.add("// };\n\n")

  # C++ standard includes
  hpp.add("#include <string>\n")
  hpp.add("#include <string_view>\n")
  hpp.add("#include <vector>\n")
  hpp.add("#include <array>\n")
  hpp.add("#include <span>\n")
  hpp.add("#include <functional>\n")
  hpp.add("#include <optional>\n")
  hpp.add("#include <mutex>\n")
  hpp.add("#include <unordered_map>\n")
  hpp.add("#include <utility>\n")
  hpp.add("#include <cstring>\n")
  hpp.add("#include <atomic>\n\n")

  hpp.add("namespace " & nsName & " {\n\n")

  # Result<T> template
  hpp.add("// Result<T> — mirrors Nim's Result[T, string]\n")
  hpp.add("template <typename T>\n")
  hpp.add("class Result {\n")
  hpp.add("    std::optional<T> value_;\n")
  hpp.add("    std::string error_;\n")
  hpp.add("public:\n")
  hpp.add("    Result(T val) : value_(std::move(val)) {}\n")
  hpp.add("    Result(std::string err) : error_(std::move(err)) {}\n")
  hpp.add("    bool ok() const { return value_.has_value(); }\n")
  hpp.add("    explicit operator bool() const { return ok(); }\n")
  hpp.add("    const T& value() const { return *value_; }\n")
  hpp.add("    T& value() { return *value_; }\n")
  hpp.add("    const T& operator*() const { return *value_; }\n")
  hpp.add("    const T* operator->() const { return &*value_; }\n")
  hpp.add("    const std::string& error() const { return error_; }\n")
  hpp.add("};\n\n")

  hpp.add("template <>\n")
  hpp.add("class Result<void> {\n")
  hpp.add("    bool ok_ = true;\n")
  hpp.add("    std::string error_;\n")
  hpp.add("public:\n")
  hpp.add("    Result() = default;\n")
  hpp.add("    Result(std::string err) : ok_(false), error_(std::move(err)) {}\n")
  hpp.add("    bool ok() const { return ok_; }\n")
  hpp.add("    explicit operator bool() const { return ok(); }\n")
  hpp.add("    const std::string& error() const { return error_; }\n")
  hpp.add("};\n\n")

  # C++ structs
  for s in gApiCppStructs:
    hpp.add(s.replace(ApiLibPrefixPlaceholder, apiPrefix))
    hpp.add("\n")

  hpp.add("struct " & createContextResultName & " {\n")
  hpp.add("    uint32_t ctx = 0;\n")
  hpp.add("    " & createContextResultName & "() = default;\n")
  hpp.add(
    "    explicit " & createContextResultName & "(" & libName &
      "CreateContextResult& c)\n"
  )
  hpp.add("        : ctx(c.ctx) {\n")
  hpp.add("        " & "free_" & libName & "_create_context_result(&c);\n")
  hpp.add("    }\n")
  hpp.add("};\n\n")

  hpp.add("} // namespace " & nsName & "\n\n")

  for p in gApiCppPreamble:
    hpp.add(
      p.replace("__CPP_NS__", nsName).replace("__CPP_CLASS__", className).replace(
        ApiLibPrefixPlaceholder, apiPrefix
      ) & "\n"
    )
  if gApiCppPreamble.len > 0:
    hpp.add("\n")

  # Class definition (outside namespace)
  hpp.add("class " & className & " {\n")
  hpp.add("protected:\n")
  hpp.add("    uint32_t ctx_;\n\n")

  hpp.add("private:\n")
  if gApiCppPrivateMembers.len > 0:
    for m in gApiCppPrivateMembers:
      hpp.add(
        m.replace("__CPP_NS__", nsName).replace("__CPP_CLASS__", className).replace(
          ApiLibPrefixPlaceholder, apiPrefix
        ) & "\n"
      )
    hpp.add("\n")

  hpp.add("public:\n")
  var ctorInitializers = @["ctx_(0)"]
  for init in gApiCppConstructorInitializers:
    ctorInitializers.add(init)
  hpp.add("    " & className & "() : " & ctorInitializers.join(", ") & " {}\n")
  hpp.add("    virtual ~" & className & "() { shutdown(); }\n")
  hpp.add("    " & className & "(const " & className & "&) = delete;\n")
  hpp.add("    " & className & "& operator=(const " & className & "&) = delete;\n")
  hpp.add("    " & className & "(" & className & "&&) = delete;\n")
  hpp.add("    " & className & "& operator=(" & className & "&&) = delete;\n\n")
  hpp.add("    " & nsName & "::Result<void> createContext() {\n")
  hpp.add("        if (ctx_)\n")
  hpp.add(
    "            return " & nsName &
      "::Result<void>(std::string(\"Context already created\"));\n"
  )
  hpp.add("        auto c = " & libName & "_createContext();\n")
  hpp.add("        if (c.error_message) {\n")
  hpp.add("            std::string err(c.error_message);\n")
  hpp.add("            " & "free_" & libName & "_create_context_result(&c);\n")
  hpp.add("            return " & nsName & "::Result<void>(std::move(err));\n")
  hpp.add("        }\n")
  hpp.add("        ctx_ = c.ctx;\n")
  hpp.add("        " & "free_" & libName & "_create_context_result(&c);\n")
  hpp.add("        if (!ctx_)\n")
  hpp.add(
    "            return " & nsName &
      "::Result<void>(std::string(\"createContext failed\"));\n"
  )
  hpp.add("        return " & nsName & "::Result<void>();\n")
  hpp.add("    }\n")
  hpp.add("    bool validContext() const noexcept { return ctx_ != 0; }\n")
  hpp.add("    explicit operator bool() const noexcept { return validContext(); }\n")
  hpp.add("    void shutdown() noexcept {\n")
  for stmt in gApiCppShutdownStatements:
    hpp.add(
      "        " &
        stmt.replace("__CPP_NS__", nsName).replace("__CPP_CLASS__", className).replace(
          ApiLibPrefixPlaceholder, apiPrefix
        ) & "\n"
    )
  hpp.add("        if (ctx_) { " & libName & "_shutdown(ctx_); ctx_ = 0; }\n")
  hpp.add("    }\n")
  hpp.add("    uint32_t ctx() const noexcept { return ctx_; }\n\n")
  for cppMethod in gApiCppClassMethods:
    hpp.add(
      "    " &
        cppMethod
        .replace("__CPP_NS__", nsName)
        .replace("__CPP_CLASS__", className)
        .replace(ApiLibPrefixPlaceholder, apiPrefix) & "\n"
    )
  hpp.add("};\n\n")

  try:
    writeFile(hppPath, hpp)
  except IOError:
    error(
      "Failed to write generated C++ header file '" & hppPath & "': " &
        getCurrentExceptionMsg()
    )

{.push raises: [].}
{.pop.}
