## Generated C++ header-only wrapper for the CBOR FFI surface.
##
## The wrapper lives entirely in headers — no separate translation
## unit — so foreign C++ projects only need to link the Nim-built
## shared library and `#include` the generated `<lib>.hpp`.
##
## Phase 4c emits typed C++ structs + JSONCONS_ALL_MEMBER_TRAITS macros
## for each registered request response, request args, and event
## payload type, and per-request methods on the `Lib` class that
## CBOR-encode the args, dispatch through the C gate, and decode the
## response envelope into a `Result<T>`.
##
## The wrapper requires:
##   - C++17 (std::optional, structured bindings, nested namespaces)
##   - jsoncons + jsoncons_ext/cbor headers in the include path
##
## Currently supported field/parameter Nim types: bool, int/int8..int64,
## uint8..uint64, float32/float64, string. seq[T], array[N, T], Option[T],
## and nested objects are deferred to a later phase that exercises the
## full type-mapping matrix (Phase 7).

{.push raises: [].}

import std/[macros, os, strutils]
import ./api_codegen_c, ./api_common, ./api_schema

# ---------------------------------------------------------------------------
# Nim → C++ type mapping
# ---------------------------------------------------------------------------

proc nimTypeToCppType*(nimType: string): string {.compileTime.} =
  ## Map a Nim type name to its C++ equivalent. Only primitive types are
  ## supported in this phase — the typed wrapper emission falls back to
  ## a marker comment for anything outside this table.
  case nimType.strip()
  of "bool": "bool"
  of "string": "std::string"
  of "int", "int64": "int64_t"
  of "int8": "int8_t"
  of "int16": "int16_t"
  of "int32": "int32_t"
  of "uint", "uint64": "uint64_t"
  of "uint8", "byte": "uint8_t"
  of "uint16": "uint16_t"
  of "uint32": "uint32_t"
  of "float32": "float"
  of "float", "float64": "double"
  of "char": "char"
  else: ""

proc isCppMappable*(nimType: string): bool {.compileTime.} =
  nimTypeToCppType(nimType).len > 0

# ---------------------------------------------------------------------------
# Identifier helpers
# ---------------------------------------------------------------------------

proc snakeToLowerCamel*(s: string): string {.compileTime.} =
  ## "get_status" -> "getStatus", "add_numbers" -> "addNumbers".
  result = ""
  var capitalize = false
  for ch in s:
    if ch == '_':
      capitalize = true
    elif capitalize:
      result.add(toUpperAscii(ch))
      capitalize = false
    else:
      result.add(ch)

# ---------------------------------------------------------------------------
# Per-type emission
# ---------------------------------------------------------------------------

proc emitCppStructFields*(h: var string, entry: ApiTypeEntry): bool {.compileTime.} =
  ## Emit the body of a C++ struct mirroring `entry.fields`. Returns true
  ## when every field was successfully mapped. False (with a TODO comment
  ## emitted) means the wrapper should skip emitting this type's typed
  ## method to avoid handing out a half-mapped surface.
  result = true
  for f in entry.fields:
    let cppType = nimTypeToCppType(f.nimType)
    if cppType.len == 0:
      h.add("  // TODO: Nim type '" & f.nimType & "' not yet mappable to C++\n")
      result = false
    else:
      h.add("  " & cppType & " " & f.name & "{};\n")

proc emitMemberTraitsMacro*(
    h: var string, qualifiedName: string, fieldNames: seq[string]
) {.compileTime.} =
  ## Emit `JSONCONS_ALL_MEMBER_TRAITS(<qualifiedName>, f1, f2, ...)`.
  ##
  ## Per jsoncons documentation, these macros generate partial
  ## specialisations of `jsoncons::json_type_traits` and must be invoked
  ## at a namespace scope that encloses `jsoncons` — in practice, global
  ## scope outside the user's namespace, with the type fully qualified.
  ## Empty structs skip the macro entirely; jsoncons handles them
  ## implicitly when nested via Option fields.
  if fieldNames.len == 0:
    return
  h.add("JSONCONS_ALL_MEMBER_TRAITS(" & qualifiedName)
  for n in fieldNames:
    h.add(", " & n)
  h.add(")\n")

proc emitEnvelopeTraits*(h: var string, qualifiedName: string) {.compileTime.} =
  ## Emit the JSONCONS macro for `<libname>::<Type>Envelope`. Both fields
  ## are optional on the wire (`omitOptionalFields = true` in the
  ## BrokerCbor flavor), so the required-count is 0.
  h.add("JSONCONS_N_MEMBER_TRAITS(" & qualifiedName & ", 0, ok, err)\n")

# ---------------------------------------------------------------------------
# Header file emission
# ---------------------------------------------------------------------------

{.pop.}

proc generateCborCppHeaderFile*(
    outDir: string,
    libName: string,
    requestEntries: seq[CborRequestEntry],
    eventEntries: seq[CborEventEntry],
) {.compileTime, raises: [].} =
  ## Writes the C++ wrapper header (.hpp) for a CBOR-mode library.
  ensureGeneratedOutputDir(outDir)

  let guardName = libName.toUpperAscii().replace("-", "_") & "_HPP"
  let headerPath =
    if outDir.len > 0:
      outDir & "/" & libName & ".hpp"
    else:
      libName & ".hpp"
  let p = libName & "_"

  # Collect the set of payload types we need to emit C++ structs for:
  # request responses + event payloads. Keep the order stable for
  # deterministic codegen (request order, then events).
  var payloadTypeNames: seq[string] = @[]
  for e in requestEntries:
    if e.responseTypeName.len > 0 and e.responseTypeName notin payloadTypeNames:
      payloadTypeNames.add(e.responseTypeName)
  for e in eventEntries:
    if e.typeName.len > 0 and e.typeName notin payloadTypeNames:
      payloadTypeNames.add(e.typeName)

  # Walk the type registry to validate every payload is registered and is
  # an object kind. Anything else (alias / distinct / enum) gets a TODO
  # comment for now.
  var emittablePayloads: seq[string] = @[]
  for name in payloadTypeNames:
    if not isTypeRegistered(name):
      continue
    let entry = lookupTypeEntry(name)
    if entry.kind == atkObject:
      emittablePayloads.add(name)

  var h =
    "// Generated by nim-brokers CBOR FFI codegen — do not edit.\n" & "//\n" &
    "// Header-only C++ wrapper around the C ABI declared in `" & libName & ".h`.\n" &
    "// Requires C++17 and jsoncons + jsoncons_ext/cbor in the include path.\n" &
    "#ifndef " & guardName & "\n" & "#define " & guardName & "\n\n" & "#include \"" &
    libName & ".h\"\n\n" & "#include <jsoncons/json.hpp>\n" &
    "#include <jsoncons_ext/cbor/cbor.hpp>\n\n" & "#include <cstdint>\n" &
    "#include <cstring>\n" & "#include <functional>\n" & "#include <memory>\n" &
    "#include <optional>\n" & "#include <string>\n" & "#include <unordered_map>\n" &
    "#include <utility>\n" & "#include <vector>\n\n" & "namespace " & libName & " {\n\n"

  # Result<T>
  h.add("// Minimal Result<T> mirroring Nim's Result[T, string] envelope on\n")
  h.add("// the wire. Constructors are private; use ok() / err() factories.\n")
  h.add("template <typename T>\n")
  h.add("class Result {\n")
  h.add(" public:\n")
  h.add("  static Result<T> ok(T value) {\n")
  h.add("    Result<T> r;\n")
  h.add("    r.ok_ = true;\n")
  h.add("    r.value_ = std::move(value);\n")
  h.add("    return r;\n")
  h.add("  }\n")
  h.add("  static Result<T> err(std::string message) {\n")
  h.add("    Result<T> r;\n")
  h.add("    r.ok_ = false;\n")
  h.add("    r.error_ = std::move(message);\n")
  h.add("    return r;\n")
  h.add("  }\n")
  h.add("  bool isOk() const { return ok_; }\n")
  h.add("  bool isErr() const { return !ok_; }\n")
  h.add("  const T& value() const { return value_; }\n")
  h.add("  T&& take() { return std::move(value_); }\n")
  h.add("  const std::string& error() const { return error_; }\n")
  h.add(" private:\n")
  h.add("  bool ok_ = false;\n")
  h.add("  T value_{};\n")
  h.add("  std::string error_;\n")
  h.add("};\n\n")

  # ---- Per-payload typed structs (declared inside the namespace) ----
  if emittablePayloads.len > 0:
    h.add("// ---- Typed payload structs ----\n\n")
  var payloadFields: seq[(string, seq[string])] = @[]
    ## Captured (typeName, [fieldName...]) for the global-scope JSONCONS
    ## macro emission below — jsoncons partial specialisations of
    ## json_type_traits must live in a namespace enclosing `jsoncons`,
    ## i.e. global scope, with the user types fully qualified.
  for name in emittablePayloads:
    let entry = lookupTypeEntry(name)
    h.add("struct " & name & " {\n")
    let allMapped = emitCppStructFields(h, entry)
    h.add("};\n")
    if allMapped:
      var fieldNames: seq[string] = @[]
      for f in entry.fields:
        fieldNames.add(f.name)
      payloadFields.add((name, fieldNames))
    h.add("\n")

  # ---- Per-request response envelope structs ----
  var envelopeNames: seq[string] = @[]
  for e in requestEntries:
    if e.responseTypeName.len == 0:
      continue
    if e.responseTypeName notin emittablePayloads:
      continue
    let envName = e.responseTypeName & "Envelope"
    h.add("struct " & envName & " {\n")
    h.add("  std::optional<" & e.responseTypeName & "> ok;\n")
    h.add("  std::optional<std::string> err;\n")
    h.add("};\n\n")
    envelopeNames.add(envName)

  # ---- Per-request args structs ----
  var argsStructByApi: seq[(string, string)] = @[] # (apiName, argsStructName)
  var argsMethodSupported: seq[(string, bool)] = @[] # (apiName, allMapped)
  var argsFields: seq[(string, seq[string])] = @[] # (typeName, [fieldName])
  for e in requestEntries:
    if e.argFields.len == 0:
      argsMethodSupported.add((e.apiName, true))
      continue
    var allMapped = true
    for (n, t) in e.argFields:
      if not isCppMappable(t):
        allMapped = false
        break
    argsMethodSupported.add((e.apiName, allMapped))
    if not allMapped:
      continue
    let camelBase = snakeToLowerCamel(e.apiName)
    # Capitalise the first letter to match C++ struct naming conventions
    # (the method itself stays lowerCamel for ergonomic call sites).
    var argsName = camelBase & "Args"
    if argsName.len > 0:
      argsName[0] = toUpperAscii(argsName[0])
    argsStructByApi.add((e.apiName, argsName))
    h.add("struct " & argsName & " {\n")
    for (n, t) in e.argFields:
      h.add("  " & nimTypeToCppType(t) & " " & n & "{};\n")
    h.add("};\n\n")
    var fieldNames: seq[string] = @[]
    for (n, t) in e.argFields:
      fieldNames.add(n)
    argsFields.add((argsName, fieldNames))

  # Lookup helpers for the Lib class body below.
  proc argsStructName(apiName: string): string {.compileTime.} =
    for (n, s) in argsStructByApi:
      if n == apiName:
        return s
    ""

  proc isMethodSupported(apiName: string): bool {.compileTime.} =
    for (n, ok) in argsMethodSupported:
      if n == apiName:
        return ok
    false

  # ----------------------------------------------------------------------
  # JSONCONS macros must be emitted at namespace scope enclosing
  # `jsoncons` (in practice: global scope), with each type fully
  # qualified. Close the namespace, emit, reopen for the Lib class.
  # ----------------------------------------------------------------------
  h.add("} // namespace " & libName & "\n\n")
  for (name, fields) in payloadFields:
    emitMemberTraitsMacro(h, libName & "::" & name, fields)
  for envName in envelopeNames:
    emitEnvelopeTraits(h, libName & "::" & envName)
  for (name, fields) in argsFields:
    emitMemberTraitsMacro(h, libName & "::" & name, fields)
  if payloadFields.len > 0 or envelopeNames.len > 0 or argsFields.len > 0:
    h.add("\n")
  h.add("namespace " & libName & " {\n\n")

  # ----------------------------------------------------------------------
  # RAII Lib class — lifecycle + typed methods + the protected rawCall.
  # ----------------------------------------------------------------------
  h.add("class Lib {\n")
  h.add(" public:\n")
  h.add("  Lib() {\n")
  h.add("    " & p & "initialize();\n")
  h.add("    char* err = nullptr;\n")
  h.add("    ctx_ = " & p & "createContext(&err);\n")
  h.add("    if (ctx_ == 0) {\n")
  h.add("      if (err != nullptr) {\n")
  h.add("        lastError_ = err;\n")
  h.add("        " & p & "freeBuffer(err);\n")
  h.add("      } else {\n")
  h.add("        lastError_ = \"createContext returned 0 with no error message\";\n")
  h.add("      }\n")
  h.add("    }\n")
  h.add("  }\n\n")
  h.add("  ~Lib() {\n")
  h.add("    if (ctx_ != 0) {\n")
  h.add("      " & p & "shutdown(ctx_);\n")
  h.add("    }\n")
  h.add("  }\n\n")
  h.add("  Lib(const Lib&) = delete;\n")
  h.add("  Lib& operator=(const Lib&) = delete;\n")
  h.add("  Lib(Lib&& other) noexcept\n")
  h.add("      : ctx_(other.ctx_), lastError_(std::move(other.lastError_)) {\n")
  h.add("    other.ctx_ = 0;\n")
  h.add("  }\n")
  h.add("  Lib& operator=(Lib&& other) noexcept {\n")
  h.add("    if (this != &other) {\n")
  h.add("      if (ctx_ != 0) " & p & "shutdown(ctx_);\n")
  h.add("      ctx_ = other.ctx_;\n")
  h.add("      lastError_ = std::move(other.lastError_);\n")
  h.add("      other.ctx_ = 0;\n")
  h.add("    }\n")
  h.add("    return *this;\n")
  h.add("  }\n\n")
  h.add("  bool isOk() const { return ctx_ != 0; }\n")
  h.add("  const std::string& lastError() const { return lastError_; }\n")
  h.add("  uint32_t context() const { return ctx_; }\n\n")

  # Per-request typed methods.
  for e in requestEntries:
    if e.responseTypeName.len == 0:
      continue
    if e.responseTypeName notin emittablePayloads:
      h.add(
        "  // TODO: '" & e.apiName & "' return type '" & e.responseTypeName &
          "' is not yet emitted as a typed C++ struct.\n"
      )
      continue
    if not isMethodSupported(e.apiName):
      h.add(
        "  // TODO: '" & e.apiName &
          "' has parameters whose Nim types aren't yet mappable to C++.\n"
      )
      continue
    let methodName = snakeToLowerCamel(e.apiName)
    let envName = e.responseTypeName & "Envelope"
    var sigParams = ""
    var argsAssign = ""
    let argsName = argsStructName(e.apiName)
    if e.argFields.len > 0:
      var first = true
      for (n, t) in e.argFields:
        if not first:
          sigParams.add(", ")
        sigParams.add(nimTypeToCppType(t) & " " & n)
        argsAssign.add("    args." & n & " = " & n & ";\n")
        first = false
    h.add(
      "  Result<" & e.responseTypeName & "> " & methodName & "(" & sigParams & ") {\n"
    )
    h.add("    std::vector<uint8_t> reqBuf;\n")
    if e.argFields.len > 0:
      h.add("    " & argsName & " args;\n")
      h.add(argsAssign)
      h.add("    try {\n")
      h.add("      jsoncons::cbor::encode_cbor(args, reqBuf);\n")
      h.add("    } catch (const std::exception& e) {\n")
      h.add(
        "      return Result<" & e.responseTypeName &
          ">::err(std::string(\"encode failed: \") + e.what());\n"
      )
      h.add("    }\n")
    h.add("    auto resp = rawCall(\"" & e.apiName & "\", reqBuf);\n")
    h.add("    if (resp.empty()) {\n")
    h.add("      return Result<" & e.responseTypeName & ">::err(lastError_);\n")
    h.add("    }\n")
    h.add("    " & envName & " env;\n")
    h.add("    try {\n")
    h.add("      env = jsoncons::cbor::decode_cbor<" & envName & ">(resp);\n")
    h.add("    } catch (const std::exception& e) {\n")
    h.add(
      "      return Result<" & e.responseTypeName &
        ">::err(std::string(\"decode failed: \") + e.what());\n"
    )
    h.add("    }\n")
    h.add("    if (env.err.has_value()) {\n")
    h.add("      return Result<" & e.responseTypeName & ">::err(*env.err);\n")
    h.add("    }\n")
    h.add("    if (env.ok.has_value()) {\n")
    h.add("      return Result<" & e.responseTypeName & ">::ok(std::move(*env.ok));\n")
    h.add("    }\n")
    h.add(
      "    return Result<" & e.responseTypeName &
        ">::err(\"malformed response envelope\");\n"
    )
    h.add("  }\n\n")

  # ----- Per-event typed subscribe / unsubscribe -----
  # Layout per event:
  #   - Public type alias `<Event>Handler` for the user-facing
  #     std::function signature.
  #   - Public subscribe(handler) and unsubscribe(handle) methods.
  #   - Private static trampoline (cdecl-callable on x86_64 / arm64) that
  #     decodes CBOR and invokes the user handler.
  #   - Private std::unordered_map<uint64_t, std::shared_ptr<Handler>>
  #     keeping each handler alive for as long as the C library has the
  #     userData pointer.
  var trampolineMembers = newStringOfCap(0)
  var handlerMapMembers = newStringOfCap(0)
  for ev in eventEntries:
    if ev.typeName.len == 0 or ev.typeName notin emittablePayloads:
      h.add(
        "  // TODO: event '" & ev.apiName & "' payload type '" & ev.typeName &
          "' is not yet emitted as a typed C++ struct.\n"
      )
      continue
    let camelBase = snakeToLowerCamel(ev.apiName)
    var pascal = camelBase
    if pascal.len > 0:
      pascal[0] = toUpperAscii(pascal[0])
    let handlerAlias = ev.typeName & "Handler"
    let trampolineIdent = ev.typeName & "Trampoline"
    let mapIdent = ev.typeName & "Handlers_"
    let subscribeName = "subscribe" & pascal
    let unsubscribeName = "unsubscribe" & pascal

    h.add(
      "  using " & handlerAlias & " = std::function<void(const " & ev.typeName &
        "&)>;\n\n"
    )
    h.add("  uint64_t " & subscribeName & "(" & handlerAlias & " handler) {\n")
    h.add("    auto sp = std::make_shared<" & handlerAlias & ">(std::move(handler));\n")
    h.add(
      "    const uint64_t id = " & p & "subscribe(\n" & "        ctx_, \"" & ev.apiName &
        "\", &Lib::" & trampolineIdent & ", sp.get());\n"
    )
    h.add("    if (id == 0 || id == 1) {\n")
    h.add("      // 0 = framework error, 1 = probe sentinel; neither owns a\n")
    h.add("      // real subscription, so don't track.\n")
    h.add("      return id;\n")
    h.add("    }\n")
    h.add("    " & mapIdent & "[id] = std::move(sp);\n")
    h.add("    return id;\n")
    h.add("  }\n\n")

    h.add(
      "  int32_t " & unsubscribeName & "(uint64_t handle) {\n" &
        "    const int32_t status = " & p & "unsubscribe(\n" & "        ctx_, \"" &
        ev.apiName & "\", handle);\n" & "    if (status == 0) {\n" &
        "      if (handle == 0) {\n" & "        " & mapIdent & ".clear();\n" &
        "      } else {\n" & "        " & mapIdent & ".erase(handle);\n" & "      }\n" &
        "    }\n" & "    return status;\n" & "  }\n\n"
    )

    # Static trampoline; built body kept inline for header-only use.
    trampolineMembers.add(
      "  static void " & trampolineIdent & "(uint32_t /*ctx*/,\n" &
        "                                    const char* /*eventName*/,\n" &
        "                                    const void* payloadBuf,\n" &
        "                                    int32_t payloadLen,\n" &
        "                                    void* userData) {\n" &
        "    if (userData == nullptr) {\n      return;\n    }\n" &
        "    auto* fn = static_cast<" & handlerAlias & "*>(userData);\n" &
        "    if (payloadBuf == nullptr || payloadLen <= 0) {\n      return;\n    }\n" &
        "    try {\n" & "      auto evt = jsoncons::cbor::decode_cbor<" & ev.typeName &
        ">(\n" & "          std::vector<uint8_t>(\n" &
        "              static_cast<const uint8_t*>(payloadBuf),\n" &
        "              static_cast<const uint8_t*>(payloadBuf) + payloadLen));\n" &
        "      (*fn)(evt);\n" & "    } catch (const std::exception&) {\n" &
        "      // Swallow decode failures rather than letting an exception\n" &
        "      // escape into the C calling thread.\n" & "    }\n" & "  }\n\n"
    )

    handlerMapMembers.add(
      "  std::unordered_map<uint64_t, std::shared_ptr<" & handlerAlias & ">> " & mapIdent &
        ";\n"
    )

  h.add("  // ---- Discovery (Phase 6) -----------------------------------\n")
  h.add("  // Returns the raw CBOR-encoded ApiList. Decode with jsoncons or\n")
  h.add("  // any other CBOR reader. Empty vector on framework error.\n")
  h.add("  std::vector<uint8_t> rawListApis() {\n")
  h.add("    void* respBuf = nullptr;\n")
  h.add("    int32_t respLen = 0;\n")
  h.add("    const int32_t status = " & p & "listApis(&respBuf, &respLen);\n")
  h.add("    std::vector<uint8_t> out;\n")
  h.add("    if (respBuf != nullptr && respLen > 0) {\n")
  h.add("      out.assign(\n")
  h.add("          static_cast<const uint8_t*>(respBuf),\n")
  h.add("          static_cast<const uint8_t*>(respBuf) + respLen);\n")
  h.add("      " & p & "freeBuffer(respBuf);\n")
  h.add("    }\n")
  h.add("    if (status != 0) {\n")
  h.add("      lastError_ = std::string(\"listApis framework error: \") +\n")
  h.add("                    std::to_string(status);\n")
  h.add("      return {};\n")
  h.add("    }\n")
  h.add("    return out;\n")
  h.add("  }\n\n")
  h.add("  // Returns the raw CBOR-encoded LibraryDescriptor.\n")
  h.add("  std::vector<uint8_t> rawGetSchema() {\n")
  h.add("    void* respBuf = nullptr;\n")
  h.add("    int32_t respLen = 0;\n")
  h.add("    const int32_t status = " & p & "getSchema(&respBuf, &respLen);\n")
  h.add("    std::vector<uint8_t> out;\n")
  h.add("    if (respBuf != nullptr && respLen > 0) {\n")
  h.add("      out.assign(\n")
  h.add("          static_cast<const uint8_t*>(respBuf),\n")
  h.add("          static_cast<const uint8_t*>(respBuf) + respLen);\n")
  h.add("      " & p & "freeBuffer(respBuf);\n")
  h.add("    }\n")
  h.add("    if (status != 0) {\n")
  h.add("      lastError_ = std::string(\"getSchema framework error: \") +\n")
  h.add("                    std::to_string(status);\n")
  h.add("      return {};\n")
  h.add("    }\n")
  h.add("    return out;\n")
  h.add("  }\n\n")
  h.add(" protected:\n")
  h.add("  // Internal: dispatch a CBOR-encoded request through the C gate\n")
  h.add("  // and return the raw response envelope bytes (or empty on\n")
  h.add("  // framework error — see lastError()).\n")
  h.add("  std::vector<uint8_t> rawCall(const char* apiName,\n")
  h.add("                                const std::vector<uint8_t>& req) {\n")
  h.add("    if (ctx_ == 0) {\n")
  h.add("      lastError_ = \"library context is not initialised\";\n")
  h.add("      return {};\n")
  h.add("    }\n")
  h.add("    void* inBuf = nullptr;\n")
  h.add("    if (!req.empty()) {\n")
  h.add("      inBuf = " & p & "allocBuffer(static_cast<int32_t>(req.size()));\n")
  h.add("      if (inBuf == nullptr) {\n")
  h.add("        lastError_ = \"allocBuffer failed\";\n")
  h.add("        return {};\n")
  h.add("      }\n")
  h.add("      std::memcpy(inBuf, req.data(), req.size());\n")
  h.add("    }\n")
  h.add("    void* respBuf = nullptr;\n")
  h.add("    int32_t respLen = 0;\n")
  h.add("    const int32_t status = " & p & "call(\n")
  h.add("        ctx_, apiName, inBuf,\n")
  h.add("        static_cast<int32_t>(req.size()), &respBuf, &respLen);\n")
  h.add("    std::vector<uint8_t> out;\n")
  h.add("    if (respBuf != nullptr && respLen > 0) {\n")
  h.add("      out.assign(\n")
  h.add("          static_cast<const uint8_t*>(respBuf),\n")
  h.add("          static_cast<const uint8_t*>(respBuf) + respLen);\n")
  h.add("      " & p & "freeBuffer(respBuf);\n")
  h.add("    }\n")
  h.add("    if (status != 0) {\n")
  h.add("      if (status == -4 && !out.empty()) {\n")
  h.add("        lastError_ = std::string(\n")
  h.add("            reinterpret_cast<const char*>(out.data()), out.size());\n")
  h.add("      } else {\n")
  h.add("        lastError_ = std::string(\"framework error: \") +\n")
  h.add("                      std::to_string(status);\n")
  h.add("      }\n")
  h.add("      return {};\n")
  h.add("    }\n")
  h.add("    return out;\n")
  h.add("  }\n\n")
  h.add(" private:\n")
  if trampolineMembers.len > 0:
    h.add(trampolineMembers)
  h.add("  uint32_t ctx_ = 0;\n")
  h.add("  std::string lastError_;\n")
  if handlerMapMembers.len > 0:
    h.add(handlerMapMembers)
  h.add("};\n\n")

  h.add("} // namespace " & libName & "\n\n")
  h.add("#endif // " & guardName & "\n")

  try:
    writeFile(headerPath, h)
  except IOError:
    error(
      "Failed to write generated CBOR C++ header '" & headerPath & "': " &
        getCurrentExceptionMsg()
    )

{.push raises: [].}
{.pop.}
