## api_codegen_cpp
## ----------------
## C++ wrapper code generation for the FFI API system.
##
## Layout produced by `generateCppHeaderFile` mirrors the CBOR-mode wrapper:
##
##   1. Header guard + includes
##   2. namespace <lib> { Result<T>, forward decls, plain payload structs }
##   3. namespace <lib>::detail { forward decls — EventDispatcher template,
##      per-event trait structs }
##   4. namespace <lib> { class Lib { declarations only;
##      private dispatcher type aliases + unique_ptr members } }
##   5. namespace <lib>::detail { full EventDispatcher template, full trait
##      definitions, adopt() functions }
##   6. namespace <lib> { inline definitions of Lib::* }
##
## The class body is interface-only: every method is declared inside the class
## and defined as a free `inline` definition below. Dispatcher implementation
## machinery is fully hidden behind the class via PIMPL (unique_ptr).

{.push raises: [].}

import std/[macros, strutils]
import ./api_codegen_c
import ./api_schema

export api_codegen_c
export api_schema

# ---------------------------------------------------------------------------
# Compile-time C++ type mapping
# ---------------------------------------------------------------------------

proc nimTypeToCpp*(nimType: NimNode): string {.compileTime.} =
  ## Maps a Nim type to its C++ equivalent.
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
  let cppType = nimTypeToCpp(nimType)
  if cppType == "std::string":
    "const std::string&"
  elif cppType.startsWith("std::vector<") or cppType.startsWith("std::array<"):
    "const " & cppType & "&"
  else:
    cppType

proc nimTypeToCppCallbackParam*(nimType: NimNode): string {.compileTime.} =
  ## Maps a Nim type to the C++ callback parameter type.
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

var gApiCppForwardDecls* {.compileTime.}: seq[string] =
  @[] ## Forward declarations of payload struct names (one line each).

var gApiCppStructs* {.compileTime.}: seq[string] =
  @[] ## Plain payload struct definitions (data members + defaults only).

var gApiCppDetailForwardDecls* {.compileTime.}: seq[string] = @[]
  ## Forward declarations emitted in detail:: BEFORE the class body
  ## (trait struct forwards). The EventDispatcher template forward is
  ## emitted automatically when gApiCppEventDispatcherEmitted is true.

var gApiCppDetailTraits* {.compileTime.}: seq[string] = @[]
  ## Full per-event trait struct definitions emitted in detail::
  ## AFTER the class body.

var gApiCppDetailAdopters* {.compileTime.}: seq[string] =
  @[] ## inline detail::adopt<Name> function definitions.

var gApiCppMethodDecls* {.compileTime.}: seq[string] =
  @[] ## Method declarations inside the class (signature; only).

var gApiCppMethodDefs* {.compileTime.}: seq[string] =
  @[] ## inline method definitions emitted after the class.

var gApiCppPrivateMembers* {.compileTime.}: seq[string] =
  @[] ## Private member field declarations (dispatchers, etc.).

var gApiCppConstructorInitializers* {.compileTime.}: seq[string] =
  @[] ## Initializer-list fragments for the ctor.

var gApiCppShutdownStatements* {.compileTime.}: seq[string] =
  @[] ## Cleanup statements for shutdown().

var gApiCppEventDispatcherEmitted* {.compileTime.}: bool = false
  ## Has the shared detail::EventDispatcher template already been emitted?

# ---------------------------------------------------------------------------
# C++ header file generation
# ---------------------------------------------------------------------------

const cppEventDispatcherTemplate = """
template <typename Owner, typename Traits, typename... CArgs>
class EventDispatcher {
public:
    using Callback = typename Traits::template Callback<Owner>;
    using CCallback = typename Traits::CCallback;

    explicit EventDispatcher(Owner& owner) noexcept
        : owner_(&owner) {}

    EventDispatcher(const EventDispatcher&) = delete;
    EventDispatcher& operator=(const EventDispatcher&) = delete;
    EventDispatcher(EventDispatcher&&) = delete;
    EventDispatcher& operator=(EventDispatcher&&) = delete;

    ~EventDispatcher() {
        clear();
    }

    uint64_t add(Callback fn) noexcept {
        std::lock_guard<std::mutex> lock(mutex_);

        if (!owner_ || owner_->ctx() == 0 || !fn) {
            return 0;
        }

        if (nativeHandle_ == 0) {
            nativeHandle_ = Traits::registerWithC(
                owner_->ctx(),
                &EventDispatcher::trampoline,
                static_cast<void*>(this)
            );
            if (nativeHandle_ == 0) {
                return 0;
            }
        }

        const uint64_t localHandle = nextLocalHandle_++;
        try {
            callbacks_.emplace(localHandle, std::move(fn));
            return localHandle;
        } catch (...) {
            if (callbacks_.empty() && nativeHandle_ != 0) {
                Traits::unregisterWithC(owner_->ctx(), nativeHandle_);
                nativeHandle_ = 0;
            }
            return 0;
        }
    }

    void remove(uint64_t localHandle) noexcept {
        std::lock_guard<std::mutex> lock(mutex_);

        callbacks_.erase(localHandle);
        if (callbacks_.empty() && nativeHandle_ != 0) {
            if (owner_ && owner_->ctx() != 0) {
                Traits::unregisterWithC(owner_->ctx(), nativeHandle_);
            }
            nativeHandle_ = 0;
        }
    }

    void clear() noexcept {
        std::lock_guard<std::mutex> lock(mutex_);

        callbacks_.clear();
        if (nativeHandle_ != 0) {
            if (owner_ && owner_->ctx() != 0) {
                Traits::unregisterWithC(owner_->ctx(), nativeHandle_);
            }
            nativeHandle_ = 0;
        }
    }

private:
    static void trampoline(uint32_t ctx, void* userData, CArgs... args) noexcept {
        auto* self = static_cast<EventDispatcher*>(userData);
        if (!self) {
            return;
        }
        self->deliver(ctx, args...);
    }

    void deliver(uint32_t ctx, CArgs... args) noexcept {
        std::vector<Callback> snapshot;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!owner_ || ctx != owner_->ctx()) {
                return;
            }

            try {
                snapshot.reserve(callbacks_.size());
                for (const auto& [id, fn] : callbacks_) {
                    if (fn) {
                        snapshot.push_back(fn);
                    }
                }
            } catch (...) {
                return;
            }
        }

        for (const auto& fn : snapshot) {
            Traits::invoke(fn, *owner_, args...);
        }
    }

    Owner* owner_ = nullptr;
    std::mutex mutex_;
    std::unordered_map<uint64_t, Callback> callbacks_;
    uint64_t nativeHandle_ = 0;
    uint64_t nextLocalHandle_ = 1;
};
"""

{.pop.} # temporarily lift raises:[] for compile-time proc using writeFile

proc generateCppHeaderFile*(
    outDir: string, libName: string
) {.compileTime, raises: [].} =
  ## Writes the C++ wrapper header file (.hpp) following the CBOR-mode layout:
  ## payload structs first, detail:: second, class declarations next, inline
  ## definitions last.
  if gApiCppMethodDecls.len == 0:
    return # No C++ content to generate

  ensureGeneratedOutputDir(outDir)
  let hppPath =
    if outDir.len > 0:
      outDir & "/" & libName & ".hpp"
    else:
      libName & ".hpp"
  let apiPrefix = libName & "_"

  # Derive class name from library name (e.g. "mylib" -> "Mylib")
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

  proc subst(s: string): string =
    s.replace("__CPP_NS__", nsName).replace("__CPP_CLASS__", className).replace(
      ApiLibPrefixPlaceholder, apiPrefix
    )

  var hpp = "#pragma once\n\n"
  hpp.add("#include \"" & libName & ".h\"\n\n")

  # Standard library includes
  hpp.add("#include <array>\n")
  hpp.add("#include <atomic>\n")
  hpp.add("#include <cstring>\n")
  hpp.add("#include <functional>\n")
  hpp.add("#include <memory>\n")
  hpp.add("#include <mutex>\n")
  hpp.add("#include <optional>\n")
  hpp.add("#include <span>\n")
  hpp.add("#include <string>\n")
  hpp.add("#include <string_view>\n")
  hpp.add("#include <unordered_map>\n")
  hpp.add("#include <utility>\n")
  hpp.add("#include <vector>\n\n")

  # ---- namespace <ns> { Result<T>, forwards, payload structs } ----
  hpp.add("namespace " & nsName & " {\n\n")

  hpp.add("// Result<T> -- mirrors Nim's Result[T, string]\n")
  hpp.add("template <typename T>\n")
  hpp.add("class Result {\n")
  hpp.add("    std::optional<T> value_;\n")
  hpp.add("    std::string error_;\n")
  hpp.add("public:\n")
  hpp.add("    Result(T val) : value_(std::move(val)) {}\n")
  hpp.add("    Result(std::string err) : error_(std::move(err)) {}\n")
  hpp.add("    bool isOk() const { return value_.has_value(); }\n")
  hpp.add("    bool isErr() const { return !value_.has_value(); }\n")
  hpp.add("    explicit operator bool() const { return isOk(); }\n")
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
  hpp.add("    bool isOk() const { return ok_; }\n")
  hpp.add("    bool isErr() const { return !ok_; }\n")
  hpp.add("    explicit operator bool() const { return isOk(); }\n")
  hpp.add("    const std::string& error() const { return error_; }\n")
  hpp.add("};\n\n")

  # Forward declarations
  hpp.add("// ---- Forward declarations ----\n")
  hpp.add("class " & className & ";\n")
  for fwd in gApiCppForwardDecls:
    hpp.add(subst(fwd) & "\n")
  hpp.add("\n")

  # Plain payload structs (data only)
  hpp.add("// ---- Payload structs ----\n")
  for s in gApiCppStructs:
    hpp.add(subst(s))
    hpp.add("\n")

  hpp.add("} // namespace " & nsName & "\n\n")

  # ---- namespace <ns>::detail { forward declarations } ----
  hpp.add("namespace " & nsName & "::detail {\n\n")

  if gApiCppEventDispatcherEmitted:
    hpp.add("template <typename Owner, typename Traits, typename... CArgs>\n")
    hpp.add("class EventDispatcher;\n\n")

  for fwd in gApiCppDetailForwardDecls:
    hpp.add(subst(fwd) & "\n")
  if gApiCppDetailForwardDecls.len > 0:
    hpp.add("\n")

  hpp.add("} // namespace " & nsName & "::detail\n\n")

  # ---- namespace <ns> { class Lib } ----
  hpp.add("namespace " & nsName & " {\n\n")

  hpp.add("class " & className & " {\n")
  hpp.add("public:\n")
  hpp.add("    " & className & "();\n")
  hpp.add("    ~" & className & "();\n")
  hpp.add("    " & className & "(const " & className & "&) = delete;\n")
  hpp.add("    " & className & "& operator=(const " & className & "&) = delete;\n")
  hpp.add("    " & className & "(" & className & "&&) = delete;\n")
  hpp.add("    " & className & "& operator=(" & className & "&&) = delete;\n\n")

  hpp.add("    Result<void> createContext();\n")
  hpp.add("    bool validContext() const noexcept;\n")
  hpp.add("    explicit operator bool() const noexcept;\n")
  hpp.add("    void shutdown() noexcept;\n")
  hpp.add("    uint32_t ctx() const noexcept;\n\n")

  for decl in gApiCppMethodDecls:
    hpp.add("    " & subst(decl) & "\n")

  hpp.add("\nprivate:\n")
  hpp.add("    uint32_t ctx_ = 0;\n")
  for m in gApiCppPrivateMembers:
    hpp.add(subst(m) & "\n")
  hpp.add("};\n\n")

  hpp.add("} // namespace " & nsName & "\n\n")

  # ---- namespace <ns>::detail { full definitions } ----
  hpp.add("namespace " & nsName & "::detail {\n\n")

  if gApiCppEventDispatcherEmitted:
    hpp.add(cppEventDispatcherTemplate)
    hpp.add("\n")

  for t in gApiCppDetailTraits:
    hpp.add(subst(t))
    hpp.add("\n")

  for a in gApiCppDetailAdopters:
    hpp.add(subst(a))
    hpp.add("\n")

  hpp.add("} // namespace " & nsName & "::detail\n\n")

  # ---- inline definitions ----
  hpp.add("namespace " & nsName & " {\n\n")
  hpp.add("// ---- Inline definitions ----\n\n")

  var ctorInitializers = @["ctx_(0)"]
  for init in gApiCppConstructorInitializers:
    ctorInitializers.add(subst(init))
  hpp.add("inline " & className & "::" & className & "()\n")
  hpp.add("    : " & ctorInitializers.join("\n    , ") & " {}\n\n")

  hpp.add("inline " & className & "::~" & className & "() { shutdown(); }\n\n")

  hpp.add("inline Result<void> " & className & "::createContext() {\n")
  hpp.add("    if (ctx_)\n")
  hpp.add("        return Result<void>(std::string(\"Context already created\"));\n")
  hpp.add("    auto c = " & libName & "_createContext();\n")
  hpp.add("    if (c.error_message) {\n")
  hpp.add("        std::string err(c.error_message);\n")
  hpp.add("        " & "free_" & libName & "_create_context_result(&c);\n")
  hpp.add("        return Result<void>(std::move(err));\n")
  hpp.add("    }\n")
  hpp.add("    ctx_ = c.ctx;\n")
  hpp.add("    " & "free_" & libName & "_create_context_result(&c);\n")
  hpp.add("    if (!ctx_)\n")
  hpp.add("        return Result<void>(std::string(\"createContext failed\"));\n")
  hpp.add("    return Result<void>();\n")
  hpp.add("}\n\n")

  hpp.add(
    "inline bool " & className &
      "::validContext() const noexcept { return ctx_ != 0; }\n"
  )
  hpp.add(
    "inline " & className &
      "::operator bool() const noexcept { return validContext(); }\n"
  )
  hpp.add(
    "inline uint32_t " & className & "::ctx() const noexcept { return ctx_; }\n\n"
  )

  hpp.add("inline void " & className & "::shutdown() noexcept {\n")
  for stmt in gApiCppShutdownStatements:
    hpp.add("    " & subst(stmt) & "\n")
  hpp.add("    if (ctx_) { " & libName & "_shutdown(ctx_); ctx_ = 0; }\n")
  hpp.add("}\n\n")

  for d in gApiCppMethodDefs:
    hpp.add(subst(d) & "\n\n")

  hpp.add("} // namespace " & nsName & "\n")

  try:
    writeFile(hppPath, hpp)
  except IOError:
    error(
      "Failed to write generated C++ header file '" & hppPath & "': " &
        getCurrentExceptionMsg()
    )

{.push raises: [].}
{.pop.}
