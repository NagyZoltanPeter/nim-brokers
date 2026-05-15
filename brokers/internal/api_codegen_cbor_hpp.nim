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
##   - C++20 (std::span, std::optional, structured bindings)
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

proc primCppType(nimType: string): string {.compileTime.} =
  ## Direct primitive mapping. Empty string for non-primitives.
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

proc unwrapBracket(s, head: string): string {.compileTime.} =
  ## "seq[X]" + "seq" -> "X"
  let t = s.strip()
  t[head.len + 1 .. ^2].strip()

proc parseArrayInner(s: string): string {.compileTime.} =
  ## "array[N, T]" -> "T"
  let inner = s.strip()[6 ..^ 2]
  let comma = inner.find(',')
  if comma < 0:
    return ""
  inner[comma + 1 .. ^1].strip()

proc nimTypeToCppType*(nimType: string): string {.compileTime.} =
  ## Recursive Nim → C++ type mapping. Returns "" for unmappable types
  ## (callers emit a TODO and skip the affected typed surface).
  let t = nimType.strip()
  let lower = t.toLowerAscii()
  let prim = primCppType(t)
  if prim.len > 0:
    return prim
  if lower.startsWith("seq[") and lower.endsWith("]"):
    let inner = nimTypeToCppType(unwrapBracket(t, "seq"))
    return
      if inner.len > 0:
        "std::vector<" & inner & ">"
      else:
        ""
  if lower.startsWith("array["):
    let elem = parseArrayInner(t)
    let inner = nimTypeToCppType(elem)
    # `std::vector` keeps the trait machinery uniform with seq[T] and
    # matches what jsoncons decodes a CBOR array into. The Nim side
    # range-checks the array length on decode.
    return
      if inner.len > 0:
        "std::vector<" & inner & ">"
      else:
        ""
  if lower.startsWith("option[") and lower.endsWith("]"):
    let inner = nimTypeToCppType(unwrapBracket(t, "option"))
    return
      if inner.len > 0:
        "std::optional<" & inner & ">"
      else:
        ""
  if isTypeRegistered(t):
    let entry = lookupTypeEntry(t)
    case entry.kind
    of atkObject:
      return t
    of atkEnum:
      return t
    of atkAlias, atkDistinct:
      # Recurse through the outer mapper (not just `primCppType`) so an
      # alias / distinct over a compound Nim type like `seq[byte]` maps to
      # `std::vector<uint8_t>` rather than falling through to "".
      return nimTypeToCppType(resolveUnderlyingType(t))
  ""

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
# Event callback parameter mapping
# ---------------------------------------------------------------------------
#
# For event payload fields we deliver UNPACKED positional args to user
# callbacks (mirroring native FFI mode). The parameter type differs from
# the storage type for non-POD fields:
#   string       -> std::string_view  (zero-copy view on decoded std::string)
#   seq[T]       -> std::span<const Tcpp>  (view on decoded std::vector)
#   array[N, T]  -> std::span<const Tcpp>  (CBOR decodes array into vector)
#   nested obj   -> const T&
#   primitives   -> by value
#
# `eventCallbackParamType` returns the C++ parameter type spelling.
# `eventCallbackArgExpr` returns the expression that pulls the arg out
# of the decoded payload struct (named `evt`).

proc eventCallbackParamType*(nimType: string): string {.compileTime.} =
  ## Returns the C++ parameter type for unpacked event callback args.
  ## Empty string => the field's underlying Nim type isn't mappable.
  let t = nimType.strip()
  let lower = t.toLowerAscii()
  let prim = primCppType(t)
  if prim.len > 0:
    if t == "string":
      return "std::string_view"
    return prim
  if lower.startsWith("seq[") and lower.endsWith("]"):
    let innerNim = unwrapBracket(t, "seq")
    # seq[string] -> span<const std::string_view> (parity with native FFI;
    # the trampoline materialises a temporary vector<string_view> over
    # the decoded vector<string>).
    if innerNim.strip() == "string":
      return "std::span<const std::string_view>"
    let inner = nimTypeToCppType(innerNim)
    return
      if inner.len > 0:
        "std::span<const " & inner & ">"
      else:
        ""
  if lower.startsWith("array["):
    let elem = parseArrayInner(t)
    let inner = nimTypeToCppType(elem)
    return
      if inner.len > 0:
        "std::span<const " & inner & ">"
      else:
        ""
  if lower.startsWith("option[") and lower.endsWith("]"):
    let inner = nimTypeToCppType(unwrapBracket(t, "option"))
    return
      if inner.len > 0:
        "std::optional<" & inner & ">"
      else:
        ""
  if isTypeRegistered(t):
    let entry = lookupTypeEntry(t)
    case entry.kind
    of atkObject:
      return "const " & t & "&"
    of atkEnum:
      return t
    of atkAlias, atkDistinct:
      # Recurse through the outer mapper (not just `primCppType`) so an
      # alias / distinct over a compound Nim type like `seq[byte]` maps to
      # `std::vector<uint8_t>` rather than falling through to "".
      return nimTypeToCppType(resolveUnderlyingType(t))
  ""

proc eventCallbackArgExpr*(fieldName, nimType: string): string {.compileTime.} =
  ## Builds the expression that destructures `evt.<fieldName>` into the
  ## callback param shape returned by `eventCallbackParamType`.
  let t = nimType.strip()
  let lower = t.toLowerAscii()
  if t == "string":
    return "std::string_view(evt." & fieldName & ")"
  if lower.startsWith("seq[") and lower.endsWith("]"):
    let innerNim = unwrapBracket(t, "seq")
    # seq[string]: pass a span over the temporary vector<string_view>
    # built in the invoke preamble (see eventCallbackInvokeSetup).
    if innerNim.strip() == "string":
      return "std::span<const std::string_view>(" & fieldName & "_view)"
    let inner = nimTypeToCppType(innerNim)
    if inner.len > 0:
      return "std::span<const " & inner & ">(evt." & fieldName & ")"
    return "evt." & fieldName
  if lower.startsWith("array["):
    let elem = parseArrayInner(t)
    let inner = nimTypeToCppType(elem)
    if inner.len > 0:
      return "std::span<const " & inner & ">(evt." & fieldName & ")"
    return "evt." & fieldName
  # Primitives, enums, distincts, options, nested objects: pass directly.
  "evt." & fieldName

proc eventCallbackInvokeSetup*(fieldName, nimType: string): string {.compileTime.} =
  ## Returns setup statements emitted inside `invoke()` BEFORE the user
  ## callback is called. Used to materialise non-owning views over the
  ## decoded payload (e.g. seq[string] -> vector<string_view>) so the
  ## span the user receives stays valid for the call duration.
  let t = nimType.strip()
  let lower = t.toLowerAscii()
  if lower.startsWith("seq[") and lower.endsWith("]") and
      unwrapBracket(t, "seq").strip() == "string":
    let viewVar = fieldName & "_view"
    return
      "      std::vector<std::string_view> " & viewVar & ";\n" & "      " & viewVar &
      ".reserve(evt." & fieldName & ".size());\n" & "      for (const auto& s : evt." &
      fieldName & ") " & viewVar & ".emplace_back(s);\n"
  ""

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
    h: var string,
    qualifiedName: string,
    typeName: string,
    fieldNames: seq[string],
) {.compileTime.} =
  ## Emit a JSONCONS member-traits macro for `<qualifiedName>`.
  ##
  ## When the registered struct contains any `Option[T]` field, switch
  ## from the `_ALL_` flavour (every member required) to the `_N_`
  ## flavour with `N = required.len`, listing required fields first
  ## then optional ones. Without this split, decoding a payload where
  ## an `Option` field is `none` (no key on the wire) fails with
  ## `Key 'X' not found`.
  ##
  ## Per jsoncons docs, these macros generate partial specialisations
  ## of `jsoncons::json_type_traits` and must be invoked at namespace
  ## scope enclosing `jsoncons` — i.e. global scope, type fully
  ## qualified. Empty structs are skipped; jsoncons handles those
  ## implicitly when nested via Option fields.
  if fieldNames.len == 0:
    return

  var required: seq[string] = @[]
  var optional: seq[string] = @[]
  if isTypeRegistered(typeName):
    let entry = lookupTypeEntry(typeName)
    for n in fieldNames:
      var isOption = false
      for f in entry.fields:
        if f.name == n:
          if f.nimType.toLowerAscii().startsWith("option["):
            isOption = true
          break
      if isOption:
        optional.add(n)
      else:
        required.add(n)
  else:
    required = fieldNames

  if optional.len == 0:
    h.add("JSONCONS_ALL_MEMBER_TRAITS(" & qualifiedName)
    for n in required:
      h.add(", " & n)
    h.add(")\n")
  else:
    h.add("JSONCONS_N_MEMBER_TRAITS(" & qualifiedName & ", " & $required.len)
    for n in required:
      h.add(", " & n)
    for n in optional:
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

  # Derive C++ class name from libName the same way the native codegen
  # does: snake_case / kebab-case → PascalCase. "mylib" -> "Mylib",
  # "typemappingtestlib_cbor" -> "TypemappingtestlibCbor". Keeps the
  # public C++ surface identical between native and CBOR builds so the
  # same client `main.cpp` can compile against either.
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

  # Note: emittablePayloads is computed below from the actual struct
  # emission, not from the response / event lookup, so we cover types
  # transitively referenced from object fields (seq[Tag], etc.).

  var h =
    "// Generated by nim-brokers CBOR FFI codegen — do not edit.\n" & "//\n" &
    "// Header-only C++ wrapper around the C ABI declared in `" & libName & ".h`.\n" &
    "// Requires C++20 and jsoncons + jsoncons_ext/cbor in the include path.\n" &
    "#ifndef " & guardName & "\n" & "#define " & guardName & "\n\n" & "#include \"" &
    libName & ".h\"\n\n" & "#include <jsoncons/json.hpp>\n" &
    "#include <jsoncons_ext/cbor/cbor.hpp>\n\n" & "#include <cstdint>\n" &
    "#include <cstring>\n" & "#include <functional>\n" & "#include <memory>\n" &
    "#include <optional>\n" & "#include <span>\n" & "#include <string>\n" &
    "#include <system_error>\n" & "#include <unordered_map>\n" & "#include <utility>\n" &
    "#include <vector>\n\n" & "namespace " & libName & " {\n\n"

  # Result<T>
  h.add("template <typename T>\n")
  h.add("class Result {\n")
  h.add("    std::optional<T> value_;\n")
  h.add("    std::string error_;\n")
  h.add("public:\n")
  h.add("    static Result<T> ok(T value) {\n")
  h.add("        Result<T> r;\n")
  h.add("        r.value_ = std::move(value);\n")
  h.add("        return r;\n")
  h.add("    }\n")
  h.add("    static Result<T> err(std::string message) {\n")
  h.add("        Result<T> r;\n")
  h.add("        r.error_ = std::move(message);\n")
  h.add("        return r;\n")
  h.add("    }\n")
  h.add("    bool isOk() const { return value_.has_value(); }\n")
  h.add("    bool isErr() const { return !value_.has_value(); }\n")
  h.add("    explicit operator bool() const { return isOk(); }\n")
  h.add("    const T& value() const { return *value_; }\n")
  h.add("    T& value() { return *value_; }\n")
  h.add("    const T& operator*() const { return *value_; }\n")
  h.add("    const T* operator->() const { return &*value_; }\n")
  h.add("    T&& take() { return std::move(*value_); }\n")
  h.add("    const std::string& error() const { return error_; }\n")
  h.add("};\n\n")
  h.add("template <>\n")
  h.add("class Result<void> {\n")
  h.add("    bool ok_ = true;\n")
  h.add("    std::string error_;\n")
  h.add("public:\n")
  h.add("    static Result<void> ok() {\n")
  h.add("        Result<void> r;\n")
  h.add("        r.ok_ = true;\n")
  h.add("        return r;\n")
  h.add("    }\n")
  h.add("    static Result<void> err(std::string message) {\n")
  h.add("        Result<void> r;\n")
  h.add("        r.ok_ = false;\n")
  h.add("        r.error_ = std::move(message);\n")
  h.add("        return r;\n")
  h.add("    }\n")
  h.add("    Result() = default;\n")
  h.add("    bool isOk() const { return ok_; }\n")
  h.add("    bool isErr() const { return !ok_; }\n")
  h.add("    explicit operator bool() const { return isOk(); }\n")
  h.add("    const std::string& error() const { return error_; }\n")
  h.add("};\n\n")

  # ---- All registered enums + distinct/alias aliases + structs ----
  # We walk gApiTypeRegistry directly so types referenced from fields
  # (e.g. `seq[Tag]` inside an object) get emitted, not just the
  # immediate request-response or event-payload types.
  var enumNames: seq[string] = @[]
  var aliasNames: seq[string] = @[]
  var objectNames: seq[string] = @[]
  for entry in gApiTypeRegistry:
    if entry.name.endsWith("CborArgs"):
      continue # synthetic args structs are emitted per-request below
    case entry.kind
    of atkEnum:
      enumNames.add(entry.name)
    of atkDistinct, atkAlias:
      aliasNames.add(entry.name)
    of atkObject:
      objectNames.add(entry.name)

  # Enum class declarations — the underlying type is fixed at int32_t so
  # the wire encoding (CBOR Unsigned, ordinal value) round-trips with
  # the BrokerCbor flavor's `enumRep = EnumAsNumber`.
  if enumNames.len > 0:
    h.add("// ---- Enums ----\n\n")
  for name in enumNames:
    let entry = lookupTypeEntry(name)
    h.add("enum class " & name & " : int32_t {\n")
    if entry.enumValues.len == 0:
      h.add("};\n\n")
      continue
    for v in entry.enumValues:
      h.add("  " & v.name & " = " & $v.ordinal & ",\n")
    h.add("};\n\n")

  # Distinct / alias — plain `using` aliases of the underlying primitive.
  if aliasNames.len > 0:
    h.add("// ---- Distinct / alias types ----\n\n")
  for name in aliasNames:
    let underlying = resolveUnderlyingType(name)
    let prim = primCppType(underlying)
    if prim.len == 0:
      h.add(
        "// TODO: alias '" & name & "' resolves to '" & underlying &
          "' which has no C++ primitive mapping\n\n"
      )
      continue
    h.add("using " & name & " = " & prim & ";\n")
  if aliasNames.len > 0:
    h.add("\n")

  # Object structs — emit forward declarations first so cross-references
  # (e.g. `std::vector<Tag>` inside another struct) compile regardless
  # of registry order.
  if objectNames.len > 0:
    h.add("// ---- Object payload structs ----\n\n")
    for name in objectNames:
      h.add("struct " & name & ";\n")
    h.add("\n")

  # Captured (typeName, [fieldName...]) for global-scope JSONCONS macros.
  var payloadFields: seq[(string, seq[string])] = @[]
  for name in objectNames:
    let entry = lookupTypeEntry(name)
    h.add("struct " & name & " {\n")
    var allMapped = true
    for f in entry.fields:
      let cppType = nimTypeToCppType(f.nimType)
      if cppType.len == 0:
        h.add("  // TODO: Nim type '" & f.nimType & "' not yet mappable\n")
        allMapped = false
      else:
        h.add("  " & cppType & " " & f.name & "{};\n")
    h.add("};\n")
    if allMapped:
      var fieldNames: seq[string] = @[]
      for f in entry.fields:
        fieldNames.add(f.name)
      payloadFields.add((name, fieldNames))
    h.add("\n")

  # Names of object types we successfully emitted with full field
  # coverage — used to gate request/event method emission below.
  var emittablePayloads: seq[string] = @[]
  for (name, _) in payloadFields:
    emittablePayloads.add(name)

  # ---- Compute envelope / args metadata (no emission yet) ----
  var envelopeNames: seq[string] = @[]
  for e in requestEntries:
    if e.responseTypeName.len == 0:
      continue
    if e.responseTypeName notin emittablePayloads:
      continue
    let envName = e.responseTypeName & "Envelope"
    if envName notin envelopeNames:
      envelopeNames.add(envName)

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
    var argsName = camelBase & "Args"
    if argsName.len > 0:
      argsName[0] = toUpperAscii(argsName[0])
    argsStructByApi.add((e.apiName, argsName))
    var fieldNames: seq[string] = @[]
    for (n, t) in e.argFields:
      fieldNames.add(n)
    argsFields.add((argsName, fieldNames))

  # Lookup helpers.
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

  # Pre-compute event eligibility: an event is "emittable" iff its payload
  # struct was fully mapped AND every field has an unpacked-callback param
  # mapping (string -> string_view, seq -> span, etc.).
  var emittableEvents: seq[CborEventEntry] = @[]
  for ev in eventEntries:
    if ev.typeName.len == 0 or ev.typeName notin emittablePayloads:
      continue
    let entry = lookupTypeEntry(ev.typeName)
    var allOk = true
    for f in entry.fields:
      if eventCallbackParamType(f.nimType).len == 0:
        allOk = false
        break
    if allOk:
      emittableEvents.add(ev)

  # ==================================================================
  # Section 0.5: detail:: forward declarations (so Lib can name them)
  # ==================================================================
  h.add("namespace detail {\n")
  h.add("template <typename Owner, typename Traits>\n")
  h.add("class EventDispatcher;\n\n")
  for ev in emittableEvents:
    h.add("struct " & ev.typeName & "EventTraits;\n")
  h.add("} // namespace detail\n\n")

  # ==================================================================
  # Section 1: Lib class — declarations only (no detail:: dependencies)
  # ==================================================================
  h.add("class " & className & " {\n")
  h.add(" public:\n")
  h.add("  " & className & "();\n")
  h.add("  ~" & className & "();\n")
  h.add("  " & className & "(const " & className & "&) = delete;\n")
  h.add("  " & className & "& operator=(const " & className & "&) = delete;\n")
  h.add("  " & className & "(" & className & "&&) = delete;\n")
  h.add("  " & className & "& operator=(" & className & "&&) = delete;\n\n")
  h.add("  static std::string_view version() noexcept;\n\n")
  h.add("  Result<void> createContext();\n")
  h.add("  bool validContext() const noexcept;\n")
  h.add("  explicit operator bool() const noexcept;\n")
  h.add("  void shutdown() noexcept;\n")
  h.add("  uint32_t ctx() const noexcept;\n\n")

  # Per-request method declarations.
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
    var sigParams = ""
    if e.argFields.len > 0:
      var first = true
      for (n, t) in e.argFields:
        if not first:
          sigParams.add(", ")
        sigParams.add(nimTypeToCppType(t) & " " & n)
        first = false
    h.add(
      "  Result<" & e.responseTypeName & "> " & methodName & "(" & sigParams & ");\n"
    )
  h.add("\n")

  # Per-event Callback aliases + on/off declarations. The public alias is
  # emitted as a fully-spelled `std::function<...>` (mirrors native FFI)
  # so that Lib's public surface does NOT depend on the detail::Traits
  # struct being complete at this point — only forward-declared. The
  # EventDispatcher's internal `Callback` typedef (resolved from Traits
  # later) produces the same std::function<> instantiation, so the types
  # are interchangeable at call sites.
  for ev in eventEntries:
    if ev notin emittableEvents:
      h.add(
        "  // TODO: event '" & ev.apiName & "' payload type '" & ev.typeName &
          "' is not yet emitted as a typed C++ struct.\n"
      )
      continue
    let entry = lookupTypeEntry(ev.typeName)
    let camelBase = snakeToLowerCamel(ev.apiName)
    var pascal = camelBase
    if pascal.len > 0:
      pascal[0] = toUpperAscii(pascal[0])
    let callbackAlias = ev.typeName & "Callback"
    let onName = "on" & pascal
    let offName = "off" & pascal
    h.add("  using " & callbackAlias & " = std::function<void(" & className & "&")
    for f in entry.fields:
      h.add(", " & eventCallbackParamType(f.nimType) & " " & f.name)
    h.add(")>;\n")
    h.add("  uint64_t " & onName & "(" & callbackAlias & " fn) noexcept;\n")
    h.add("  void " & offName & "(uint64_t handle = 0) noexcept;\n\n")

  # Discovery declarations.
  h.add("  std::string listApis();\n")
  h.add("  std::string getSchema();\n\n")

  # Private section: dispatcher members + ctx + lastError scratch.
  h.add(" private:\n")
  h.add("  uint32_t ctx_ = 0;\n")
  h.add("  std::string lastError_;\n")
  for ev in emittableEvents:
    let dispatcherType = ev.typeName & "Dispatcher"
    let dispatcherMember = ev.apiName & "Dispatcher_"
    h.add(
      "  using " & dispatcherType & " = detail::EventDispatcher<" & className &
        ", detail::" & ev.typeName & "EventTraits>;\n"
    )
    h.add("  std::unique_ptr<" & dispatcherType & "> " & dispatcherMember & ";\n")
  h.add("};\n\n")

  # ==================================================================
  # Section 3: Envelope + args structs (internal plumbing, after class)
  # ==================================================================
  var emittedEnvelopes: seq[string] = @[]
  for e in requestEntries:
    if e.responseTypeName.len == 0:
      continue
    if e.responseTypeName notin emittablePayloads:
      continue
    if e.responseTypeName in emittedEnvelopes:
      continue
    emittedEnvelopes.add(e.responseTypeName)
    let envName = e.responseTypeName & "Envelope"
    h.add("struct " & envName & " {\n")
    h.add("  std::optional<" & e.responseTypeName & "> ok;\n")
    h.add("  std::optional<std::string> err;\n")
    h.add("};\n\n")

  for e in requestEntries:
    if e.argFields.len == 0:
      continue
    if not isMethodSupported(e.apiName):
      continue
    let an = argsStructName(e.apiName)
    if an.len == 0:
      continue
    h.add("struct " & an & " {\n")
    for (n, t) in e.argFields:
      h.add("  " & nimTypeToCppType(t) & " " & n & "{};\n")
    h.add("};\n\n")

  # ==================================================================
  # Section 4: JSONCONS macros (global scope)
  # ==================================================================
  h.add("} // namespace " & libName & "\n\n")

  if enumNames.len > 0:
    h.add(
      "namespace jsoncons {\n" & "template <typename Json, typename E>\n" &
        "struct broker_int_enum_traits {\n" & "  using value_type = E;\n" &
        "  using underlying = int32_t;\n" &
        "  static constexpr bool is_compatible = true;\n" &
        "  static bool is(const Json& j) noexcept {\n" &
        "    return j.template is<underlying>();\n" & "  }\n" &
        "  static value_type as(const Json& j) {\n" &
        "    return static_cast<value_type>(j.template as<underlying>());\n" & "  }\n" &
        "  static Json to_json(value_type v) {\n" &
        "    return Json(static_cast<underlying>(v));\n" & "  }\n" &
        "  template <typename Allocator>\n" &
        "  static Json to_json(value_type v, const Allocator&) {\n" &
        "    return to_json(v);\n" & "  }\n" & "};\n"
    )
    for name in enumNames:
      let q = libName & "::" & name
      h.add(
        "template <typename Json>\n" & "struct json_type_traits<Json, " & q & ">\n" &
          "    : public broker_int_enum_traits<Json, " & q & "> {};\n"
      )
    h.add("} // namespace jsoncons\n\n")

  for (name, fields) in payloadFields:
    emitMemberTraitsMacro(h, libName & "::" & name, name, fields)
  for envName in envelopeNames:
    emitEnvelopeTraits(h, libName & "::" & envName)
  for (name, fields) in argsFields:
    # Args structs aren't in the public registry under their `<Method>Args`
    # synthesised name; the loop falls through to `required = fieldNames`
    # and behaves identically to the previous _ALL_ emission. Pass the
    # name anyway so future arg-side Option support flips on for free.
    emitMemberTraitsMacro(h, libName & "::" & name, name, fields)
  if payloadFields.len > 0 or envelopeNames.len > 0 or argsFields.len > 0:
    h.add("\n")

  # ==================================================================
  # Section 5: detail encode helpers (need JSONCONS traits above)
  # ==================================================================
  h.add("namespace " & libName & " {\n")
  h.add("namespace detail {\n\n")

  # NimBuffer RAII wrapper for Nim-allocated buffers.
  h.add("class NimBuffer {\n")
  h.add(" public:\n")
  h.add("  NimBuffer() = default;\n")
  h.add("  NimBuffer(void* p, int32_t n) noexcept : p_(p), n_(n) {}\n")
  h.add(
    "  NimBuffer(NimBuffer&& o) noexcept : p_(o.p_), n_(o.n_) { o.p_ = nullptr; o.n_ = 0; }\n"
  )
  h.add("  NimBuffer& operator=(NimBuffer&& o) noexcept {\n")
  h.add(
    "    if (this != &o) { reset(); p_ = o.p_; n_ = o.n_; o.p_ = nullptr; o.n_ = 0; }\n"
  )
  h.add("    return *this;\n")
  h.add("  }\n")
  h.add("  NimBuffer(const NimBuffer&) = delete;\n")
  h.add("  NimBuffer& operator=(const NimBuffer&) = delete;\n")
  h.add("  ~NimBuffer() { reset(); }\n")
  h.add("  void reset() noexcept {\n")
  h.add("    if (p_) { " & p & "freeBuffer(p_); p_ = nullptr; n_ = 0; }\n")
  h.add("  }\n")
  h.add("  bool empty() const noexcept { return p_ == nullptr || n_ <= 0; }\n")
  h.add("  std::span<const std::uint8_t> view() const noexcept {\n")
  h.add("    return {static_cast<const std::uint8_t*>(p_),\n")
  h.add("            static_cast<std::size_t>(n_ > 0 ? n_ : 0)};\n")
  h.add("  }\n")
  h.add(" private:\n")
  h.add("  void* p_ = nullptr;\n")
  h.add("  int32_t n_ = 0;\n")
  h.add("};\n\n")

  h.add("struct CountingSink {\n")
  h.add("  using value_type = std::uint8_t;\n")
  h.add("  std::size_t* count;\n")
  h.add("  explicit CountingSink(std::size_t& c) noexcept : count(&c) {}\n")
  h.add("  void append(const std::uint8_t*, std::size_t n) noexcept { *count += n; }\n")
  h.add("  void push_back(std::uint8_t) noexcept { ++*count; }\n")
  h.add("  void flush() noexcept {}\n")
  h.add("};\n\n")
  h.add("struct SpanSink {\n")
  h.add("  using value_type = std::uint8_t;\n")
  h.add("  std::uint8_t* dst;\n")
  h.add("  std::size_t cap;\n")
  h.add("  std::size_t* pos;\n")
  h.add("  SpanSink(std::uint8_t* d, std::size_t c, std::size_t& p) noexcept\n")
  h.add("      : dst(d), cap(c), pos(&p) {}\n")
  h.add("  void append(const std::uint8_t* s, std::size_t n) noexcept {\n")
  h.add("    std::memcpy(dst + *pos, s, n); *pos += n;\n")
  h.add("  }\n")
  h.add("  void push_back(std::uint8_t b) noexcept { dst[(*pos)++] = b; }\n")
  h.add("  void flush() noexcept {}\n")
  h.add("};\n\n")
  # jsoncons 1.7.0 moved encode_traits into the `reflect` sub-namespace and
  # renamed the entry point from `encode(v, enc, ctx, ec)` to
  # `try_encode(alloc_set, v, enc)` returning `write_result`
  # (= `expected<void, std::error_code>`).
  h.add("template <class T>\n")
  h.add("std::size_t cborEncodedSize(const T& v) {\n")
  h.add("  std::size_t n = 0;\n")
  h.add("  jsoncons::cbor::basic_cbor_encoder<CountingSink> enc{CountingSink{n}};\n")
  h.add(
    "  auto result = jsoncons::reflect::encode_traits<T>::try_encode(\n" &
      "      jsoncons::make_alloc_set(), v, enc);\n"
  )
  h.add(
    "  if (!result) throw std::system_error(result.error(), \"cbor counting pass\");\n"
  )
  h.add("  enc.flush();\n")
  h.add("  return n;\n")
  h.add("}\n\n")
  h.add("template <class T>\n")
  h.add("void cborEncodeInto(const T& v, std::uint8_t* dst, std::size_t cap) {\n")
  h.add("  std::size_t pos = 0;\n")
  h.add(
    "  jsoncons::cbor::basic_cbor_encoder<SpanSink> enc{SpanSink{dst, cap, pos}};\n"
  )
  h.add(
    "  auto result = jsoncons::reflect::encode_traits<T>::try_encode(\n" &
      "      jsoncons::make_alloc_set(), v, enc);\n"
  )
  h.add(
    "  if (!result) throw std::system_error(result.error(), \"cbor write pass\");\n"
  )
  h.add("  enc.flush();\n")
  h.add("}\n\n")
  # rawCall / rawCallOwned — free functions in detail namespace.
  h.add("inline std::pair<int32_t, NimBuffer>\n")
  h.add(
    "rawCall(uint32_t ctx, std::string& lastError,\n" &
      "        const char* apiName, const std::uint8_t* in, std::size_t inLen) {\n"
  )
  h.add("  if (ctx == 0) {\n")
  h.add("    lastError = \"library context is not initialised\";\n")
  h.add("    return {-1, NimBuffer{}};\n")
  h.add("  }\n")
  h.add("  void* inBuf = nullptr;\n")
  h.add("  if (inLen > 0) {\n")
  h.add("    inBuf = " & p & "allocBuffer(static_cast<int32_t>(inLen));\n")
  h.add(
    "    if (!inBuf) { lastError = \"allocBuffer failed\"; return {-1, NimBuffer{}}; }\n"
  )
  h.add("    std::memcpy(inBuf, in, inLen);\n")
  h.add("  }\n")
  h.add("  void* respBuf = nullptr;\n")
  h.add("  int32_t respLen = 0;\n")
  h.add("  const int32_t status = " & p & "call(\n")
  h.add(
    "      ctx, apiName, inBuf, static_cast<int32_t>(inLen), &respBuf, &respLen);\n"
  )
  h.add("  NimBuffer resp{respBuf, respLen};\n")
  h.add("  if (status != 0) {\n")
  h.add("    if (status == -4 && !resp.empty()) {\n")
  h.add("      auto v = resp.view();\n")
  h.add("      lastError.assign(reinterpret_cast<const char*>(v.data()), v.size());\n")
  h.add("    } else {\n")
  h.add("      lastError = std::string(\"framework error: \") +\n")
  h.add("                  std::to_string(status);\n")
  h.add("    }\n")
  h.add("    return {status, std::move(resp)};\n")
  h.add("  }\n")
  h.add("  return {0, std::move(resp)};\n")
  h.add("}\n\n")

  h.add("inline std::pair<int32_t, NimBuffer>\n")
  h.add(
    "rawCallOwned(uint32_t ctx, std::string& lastError,\n" &
      "             const char* apiName, void* nimInBuf, std::size_t inLen) {\n"
  )
  h.add("  if (ctx == 0) {\n")
  h.add("    if (nimInBuf) " & p & "freeBuffer(nimInBuf);\n")
  h.add("    lastError = \"library context is not initialised\";\n")
  h.add("    return {-1, NimBuffer{}};\n")
  h.add("  }\n")
  h.add("  void* respBuf = nullptr;\n")
  h.add("  int32_t respLen = 0;\n")
  h.add("  const int32_t status = " & p & "call(\n")
  h.add(
    "      ctx, apiName, nimInBuf, static_cast<int32_t>(inLen), &respBuf, &respLen);\n"
  )
  h.add("  NimBuffer resp{respBuf, respLen};\n")
  h.add("  if (status != 0) {\n")
  h.add("    if (status == -4 && !resp.empty()) {\n")
  h.add("      auto v = resp.view();\n")
  h.add("      lastError.assign(reinterpret_cast<const char*>(v.data()), v.size());\n")
  h.add("    } else {\n")
  h.add("      lastError = std::string(\"framework error: \") +\n")
  h.add("                  std::to_string(status);\n")
  h.add("    }\n")
  h.add("    return {status, std::move(resp)};\n")
  h.add("  }\n")
  h.add("  return {0, std::move(resp)};\n")
  h.add("}\n\n")

  # ---- EventDispatcher template (CBOR-flavored) ----
  # One C-level subscription per event type, lazily registered on first
  # add() and unregistered when the last user callback is removed. User
  # callbacks are stored in a local map and fanned out under a snapshot
  # taken inside the trampoline. Mirrors native FFI EventDispatcher
  # semantics without the variadic C-arg shape (CBOR cb shape is fixed).
  h.add("template <typename Owner, typename Traits>\n")
  h.add("class EventDispatcher {\n")
  h.add(" public:\n")
  h.add("  using Callback = typename Traits::template Callback<Owner>;\n")
  h.add("  using EventStruct = typename Traits::EventStruct;\n\n")
  h.add("  explicit EventDispatcher(Owner& owner) noexcept : owner_(&owner) {}\n")
  h.add("  EventDispatcher(const EventDispatcher&) = delete;\n")
  h.add("  EventDispatcher& operator=(const EventDispatcher&) = delete;\n")
  h.add("  EventDispatcher(EventDispatcher&&) = delete;\n")
  h.add("  EventDispatcher& operator=(EventDispatcher&&) = delete;\n")
  h.add("  ~EventDispatcher() { clear(); }\n\n")
  h.add("  uint64_t add(Callback fn) noexcept {\n")
  h.add("    std::lock_guard<std::mutex> lock(mutex_);\n")
  h.add("    if (!owner_ || owner_->ctx() == 0 || !fn) return 0;\n")
  h.add("    if (nativeHandle_ == 0) {\n")
  h.add("      nativeHandle_ = Traits::registerWithC(\n")
  h.add(
    "          owner_->ctx(), &EventDispatcher::trampoline, static_cast<void*>(this));\n"
  )
  h.add("      if (nativeHandle_ == 0) return 0;\n")
  h.add("    }\n")
  h.add("    const uint64_t localHandle = nextLocalHandle_++;\n")
  h.add("    try {\n")
  h.add("      callbacks_.emplace(localHandle, std::move(fn));\n")
  h.add("      return localHandle;\n")
  h.add("    } catch (...) {\n")
  h.add("      if (callbacks_.empty() && nativeHandle_ != 0) {\n")
  h.add("        Traits::unregisterWithC(owner_->ctx(), nativeHandle_);\n")
  h.add("        nativeHandle_ = 0;\n")
  h.add("      }\n")
  h.add("      return 0;\n")
  h.add("    }\n")
  h.add("  }\n\n")
  h.add("  void remove(uint64_t localHandle) noexcept {\n")
  h.add("    std::lock_guard<std::mutex> lock(mutex_);\n")
  h.add("    callbacks_.erase(localHandle);\n")
  h.add("    if (callbacks_.empty() && nativeHandle_ != 0) {\n")
  h.add("      if (owner_ && owner_->ctx() != 0)\n")
  h.add("        Traits::unregisterWithC(owner_->ctx(), nativeHandle_);\n")
  h.add("      nativeHandle_ = 0;\n")
  h.add("    }\n")
  h.add("  }\n\n")
  h.add("  void clear() noexcept {\n")
  h.add("    std::lock_guard<std::mutex> lock(mutex_);\n")
  h.add("    callbacks_.clear();\n")
  h.add("    if (nativeHandle_ != 0) {\n")
  h.add("      if (owner_ && owner_->ctx() != 0)\n")
  h.add("        Traits::unregisterWithC(owner_->ctx(), nativeHandle_);\n")
  h.add("      nativeHandle_ = 0;\n")
  h.add("    }\n")
  h.add("  }\n\n")
  h.add(" private:\n")
  h.add("  static void trampoline(uint32_t ctx, const char* /*eventName*/,\n")
  h.add("                         const void* payloadBuf, int32_t payloadLen,\n")
  h.add("                         void* userData) noexcept {\n")
  h.add("    auto* self = static_cast<EventDispatcher*>(userData);\n")
  h.add("    if (!self || !payloadBuf || payloadLen <= 0) return;\n")
  h.add("    EventStruct evt;\n")
  h.add("    try {\n")
  h.add("      std::span<const std::uint8_t> v{\n")
  h.add("          static_cast<const std::uint8_t*>(payloadBuf),\n")
  h.add("          static_cast<std::size_t>(payloadLen)};\n")
  h.add("      evt = jsoncons::cbor::decode_cbor<EventStruct>(v.begin(), v.end());\n")
  h.add("    } catch (...) { return; }\n")
  h.add("    self->deliver(ctx, evt);\n")
  h.add("  }\n\n")
  h.add("  void deliver(uint32_t ctx, const EventStruct& evt) noexcept {\n")
  h.add("    std::vector<Callback> snapshot;\n")
  h.add("    {\n")
  h.add("      std::lock_guard<std::mutex> lock(mutex_);\n")
  h.add("      if (!owner_ || ctx != owner_->ctx()) return;\n")
  h.add("      try {\n")
  h.add("        snapshot.reserve(callbacks_.size());\n")
  h.add(
    "        for (const auto& [id, fn] : callbacks_) if (fn) snapshot.push_back(fn);\n"
  )
  h.add("      } catch (...) { return; }\n")
  h.add("    }\n")
  h.add("    for (const auto& fn : snapshot) Traits::invoke(fn, *owner_, evt);\n")
  h.add("  }\n\n")
  h.add("  Owner* owner_ = nullptr;\n")
  h.add("  std::mutex mutex_;\n")
  h.add("  std::unordered_map<uint64_t, Callback> callbacks_;\n")
  h.add("  uint64_t nativeHandle_ = 0;\n")
  h.add("  uint64_t nextLocalHandle_ = 1;\n")
  h.add("};\n\n")

  # ---- Per-event Traits structs ----
  for ev in emittableEvents:
    let entry = lookupTypeEntry(ev.typeName)
    h.add("struct " & ev.typeName & "EventTraits {\n")
    h.add("  using EventStruct = " & ev.typeName & ";\n\n")
    # Callback alias: Owner&, then unpacked args.
    h.add("  template <typename Owner>\n")
    h.add("  using Callback = std::function<void(Owner&")
    for f in entry.fields:
      h.add(", " & eventCallbackParamType(f.nimType) & " " & f.name)
    h.add(")>;\n\n")
    h.add(
      "  static uint64_t registerWithC(uint32_t ctx,\n" &
        "      void (*cb)(uint32_t, const char*, const void*, int32_t, void*),\n" &
        "      void* userData) noexcept {\n"
    )
    h.add("    return " & p & "subscribe(ctx, \"" & ev.apiName & "\", cb, userData);\n")
    h.add("  }\n\n")
    h.add("  static void unregisterWithC(uint32_t ctx, uint64_t handle) noexcept {\n")
    h.add("    " & p & "unsubscribe(ctx, \"" & ev.apiName & "\", handle);\n")
    h.add("  }\n\n")
    h.add("  template <typename Owner>\n")
    h.add(
      "  static void invoke(const Callback<Owner>& fn, Owner& owner,\n" &
        "                     const " & ev.typeName & "& evt) noexcept {\n"
    )
    # Per-field setup statements (e.g. seq[string] -> vector<string_view>)
    # emitted BEFORE the try block so any temporary views the user callback
    # observes stay alive for the entire call.
    for f in entry.fields:
      let setup = eventCallbackInvokeSetup(f.name, f.nimType)
      if setup.len > 0:
        h.add(setup)
    h.add("    try {\n")
    h.add("      fn(owner")
    for f in entry.fields:
      h.add(", " & eventCallbackArgExpr(f.name, f.nimType))
    h.add(");\n")
    h.add("    } catch (...) {}\n")
    h.add("  }\n")
    h.add("};\n\n")

  h.add("} // namespace detail\n\n")

  # ==================================================================
  # Section 6: Out-of-class inline Lib method definitions
  # ==================================================================

  # ---- Lifecycle ----
  # Constructor initializes one EventDispatcher per emittable event type.
  h.add("inline " & className & "::" & className & "()")
  if emittableEvents.len > 0:
    h.add("\n")
    var first = true
    for ev in emittableEvents:
      let dispatcherType = ev.typeName & "Dispatcher"
      let dispatcherMember = ev.apiName & "Dispatcher_"
      if first:
        h.add("    : ")
        first = false
      else:
        h.add("    , ")
      h.add(dispatcherMember & "(std::make_unique<" & dispatcherType & ">(*this))\n")
    h.add(" { " & p & "initialize(); }\n\n")
  else:
    h.add(" { " & p & "initialize(); }\n\n")
  h.add("inline " & className & "::~" & className & "() { shutdown(); }\n\n")
  h.add("inline std::string_view " & className & "::version() noexcept {\n")
  h.add("  return " & p & "version();\n")
  h.add("}\n\n")
  h.add("inline Result<void> " & className & "::createContext() {\n")
  h.add("  if (ctx_)\n")
  h.add("    return Result<void>::err(\"Context already created\");\n")
  h.add("  char* err = nullptr;\n")
  h.add("  ctx_ = " & p & "createContext(&err);\n")
  h.add("  if (ctx_ == 0) {\n")
  h.add("    if (err != nullptr) {\n")
  h.add("      std::string msg(err);\n")
  h.add("      " & p & "freeBuffer(err);\n")
  h.add("      return Result<void>::err(std::move(msg));\n")
  h.add("    }\n")
  h.add("    return Result<void>::err(\"createContext failed\");\n")
  h.add("  }\n")
  h.add("  return Result<void>::ok();\n")
  h.add("}\n\n")
  h.add(
    "inline bool " & className &
      "::validContext() const noexcept { return ctx_ != 0; }\n"
  )
  h.add(
    "inline " & className &
      "::operator bool() const noexcept { return validContext(); }\n"
  )
  h.add("inline uint32_t " & className & "::ctx() const noexcept { return ctx_; }\n\n")
  # shutdown clears all event dispatchers before calling C shutdown
  h.add("inline void " & className & "::shutdown() noexcept {\n")
  for ev in emittableEvents:
    let dispatcherMember = ev.apiName & "Dispatcher_"
    h.add("  if (" & dispatcherMember & ") " & dispatcherMember & "->clear();\n")
  h.add("  if (ctx_) { " & p & "shutdown(ctx_); ctx_ = 0; }\n")
  h.add("}\n\n")

  # ---- Per-request method implementations ----
  for e in requestEntries:
    if e.responseTypeName.len == 0:
      continue
    if e.responseTypeName notin emittablePayloads:
      continue
    if not isMethodSupported(e.apiName):
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
        argsAssign.add("  args." & n & " = " & n & ";\n")
        first = false
    h.add(
      "inline Result<" & e.responseTypeName & "> " & className & "::" & methodName & "(" &
        sigParams & ") {\n"
    )
    if e.argFields.len > 0:
      h.add("  " & argsName & " args;\n")
      h.add(argsAssign)
      h.add("  std::size_t cborLen = 0;\n")
      h.add("  try { cborLen = detail::cborEncodedSize(args); }\n")
      h.add("  catch (const std::exception& ex) {\n")
      h.add(
        "    return Result<" & e.responseTypeName &
          ">::err(std::string(\"size pass failed: \") + ex.what());\n"
      )
      h.add("  }\n")
      h.add(
        "  void* inBuf = (cborLen > 0) ? " & p &
          "allocBuffer(static_cast<int32_t>(cborLen)) : nullptr;\n"
      )
      h.add("  if (cborLen > 0 && !inBuf)\n")
      h.add(
        "    return Result<" & e.responseTypeName & ">::err(\"allocBuffer failed\");\n"
      )
      h.add("  try {\n")
      h.add(
        "    if (cborLen > 0) detail::cborEncodeInto(args, static_cast<std::uint8_t*>(inBuf), cborLen);\n"
      )
      h.add("  } catch (const std::exception& ex) {\n")
      h.add("    if (inBuf) { " & p & "freeBuffer(inBuf); }\n")
      h.add(
        "    return Result<" & e.responseTypeName &
          ">::err(std::string(\"encode pass failed: \") + ex.what());\n"
      )
      h.add("  }\n")
      h.add(
        "  auto [status, resp] = detail::rawCallOwned(ctx_, lastError_, \"" & e.apiName &
          "\", inBuf, cborLen);\n"
      )
    else:
      h.add(
        "  auto [status, resp] = detail::rawCallOwned(ctx_, lastError_, \"" & e.apiName &
          "\", nullptr, 0);\n"
      )
    h.add("  if (status != 0)\n")
    h.add("    return Result<" & e.responseTypeName & ">::err(lastError_);\n")
    h.add("  if (resp.empty())\n")
    h.add("    return Result<" & e.responseTypeName & ">::err(\"empty response\");\n")
    h.add("  " & envName & " env;\n")
    h.add("  try {\n")
    h.add("    auto v = resp.view();\n")
    h.add(
      "    env = jsoncons::cbor::decode_cbor<" & envName & ">(v.begin(), v.end());\n"
    )
    h.add("  } catch (const std::exception& ex) {\n")
    h.add(
      "    return Result<" & e.responseTypeName &
        ">::err(std::string(\"decode failed: \") + ex.what());\n"
    )
    h.add("  }\n")
    h.add("  if (env.err.has_value())\n")
    h.add("    return Result<" & e.responseTypeName & ">::err(*env.err);\n")
    h.add("  if (env.ok.has_value())\n")
    h.add("    return Result<" & e.responseTypeName & ">::ok(std::move(*env.ok));\n")
    h.add(
      "  return Result<" & e.responseTypeName &
        ">::err(\"malformed response envelope\");\n"
    )
    h.add("}\n\n")

  # ---- Per-event on/off implementations (delegate to dispatcher) ----
  for ev in emittableEvents:
    let camelBase = snakeToLowerCamel(ev.apiName)
    var pascal = camelBase
    if pascal.len > 0:
      pascal[0] = toUpperAscii(pascal[0])
    let callbackAlias = ev.typeName & "Callback"
    let onName = "on" & pascal
    let offName = "off" & pascal
    let dispatcherMember = ev.apiName & "Dispatcher_"

    h.add(
      "inline uint64_t " & className & "::" & onName & "(" & callbackAlias &
        " fn) noexcept {\n"
    )
    h.add("  return " & dispatcherMember & "->add(std::move(fn));\n")
    h.add("}\n\n")

    h.add(
      "inline void " & className & "::" & offName & "(uint64_t handle) noexcept {\n"
    )
    h.add("  if (handle == 0) " & dispatcherMember & "->clear();\n")
    h.add("  else " & dispatcherMember & "->remove(handle);\n")
    h.add("}\n\n")

  # ---- Discovery implementations ----
  h.add("inline std::string " & className & "::listApis() {\n")
  h.add("  void* buf = nullptr;\n")
  h.add("  int32_t len = 0;\n")
  h.add("  const int32_t status = " & p & "listApis(&buf, &len);\n")
  h.add("  detail::NimBuffer nb{buf, len};\n")
  h.add("  if (status != 0) {\n")
  h.add("    lastError_ = std::string(\"listApis framework error: \") +\n")
  h.add("                  std::to_string(status);\n")
  h.add("    return {};\n")
  h.add("  }\n")
  h.add("  if (nb.empty()) return {};\n")
  h.add("  auto v = nb.view();\n")
  h.add("  return std::string(reinterpret_cast<const char*>(v.data()), v.size());\n")
  h.add("}\n\n")
  h.add("inline std::string " & className & "::getSchema() {\n")
  h.add("  void* buf = nullptr;\n")
  h.add("  int32_t len = 0;\n")
  h.add("  const int32_t status = " & p & "getSchema(&buf, &len);\n")
  h.add("  detail::NimBuffer nb{buf, len};\n")
  h.add("  if (status != 0) {\n")
  h.add("    lastError_ = std::string(\"getSchema framework error: \") +\n")
  h.add("                  std::to_string(status);\n")
  h.add("    return {};\n")
  h.add("  }\n")
  h.add("  if (nb.empty()) return {};\n")
  h.add("  auto v = nb.view();\n")
  h.add("  return std::string(reinterpret_cast<const char*>(v.data()), v.size());\n")
  h.add("}\n\n")

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
