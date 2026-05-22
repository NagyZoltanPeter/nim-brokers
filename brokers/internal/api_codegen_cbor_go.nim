## CBOR-mode Go wrapper code generation.
##
## Mirrors `api_codegen_cbor_rust.nim` but emits idiomatic Go with
## `(T, error)` returns. Uses `github.com/fxamacker/cbor/v2` for
## CBOR encoding/decoding (struct tags map Nim camelCase wire keys to
## Go-style PascalCase fields).
##
## Native and CBOR generations write to separate `<outDir>` trees
## (`nimlib/build/` vs `nimlib/build_cbor/`), so each generated module
## directory contains exactly one wrapper. The filename is the same in
## both modes — `<libname>.go` and `<libname>_callbacks.c` — matching
## the C/C++/Rust convention where consumers pick build vs build_cbor
## via their build system, not via build-tag selection inside the
## module.

{.push raises: [].}

import std/[macros, strutils, tables]
import ./api_common, ./api_schema

# ---------------------------------------------------------------------------
# Nim → Go type mapping (registry-aware, used in CBOR mode)
# ---------------------------------------------------------------------------

const goPrimMap = {
  "bool": "bool",
  "string": "string",
  "char": "string",
  "int": "int32",
  "int8": "int8",
  "int16": "int16",
  "int32": "int32",
  "int64": "int64",
  "uint": "uint32",
  "uint8": "uint8",
  "uint16": "uint16",
  "uint32": "uint32",
  "uint64": "uint64",
  "byte": "byte",
  "float": "float64",
  "float32": "float32",
  "float64": "float64",
}.toTable

proc isGoPrimitive(nimType: string): bool {.compileTime.} =
  nimType.strip() in goPrimMap

proc primGoHint(nimType: string): string {.compileTime.} =
  goPrimMap.getOrDefault(nimType.strip(), "")

proc unwrapBracket(s, head: string): string {.compileTime.} =
  let t = s.strip()
  t[head.len + 1 .. ^2].strip()

proc parseArrayInner(s: string): string {.compileTime.} =
  let inner = s.strip()[6 ..^ 2]
  let comma = inner.find(',')
  if comma < 0:
    return ""
  inner[comma + 1 .. ^1].strip()

proc nimTypeToGoCborHint*(nimType: string): string {.compileTime.} =
  ## Recursive Nim → Go type for CBOR mode. Returns "" when unmappable.
  let t = nimType.strip()
  let lower = t.toLowerAscii()
  if isGoPrimitive(t):
    return primGoHint(t)
  if lower.startsWith("seq[") and lower.endsWith("]"):
    let inner = nimTypeToGoCborHint(unwrapBracket(t, "seq"))
    return
      if inner.len > 0:
        # Compact CBOR for seq[byte] uses a Go []byte (cbor lib auto-detects).
        "[]" & inner
      else:
        ""
  if lower.startsWith("array["):
    let elem = parseArrayInner(t)
    let inner = nimTypeToGoCborHint(elem)
    return
      if inner.len > 0:
        "[]" & inner
      else:
        ""
  if lower.startsWith("option[") and lower.endsWith("]"):
    let inner = nimTypeToGoCborHint(unwrapBracket(t, "option"))
    return
      if inner.len > 0:
        "*" & inner
      else:
        ""
  if isTypeRegistered(t):
    let entry = lookupTypeEntry(t)
    case entry.kind
    of atkObject, atkEnum:
      return t
    of atkAlias, atkDistinct:
      # Recurse via outer mapper for distinct/alias-over-compound (e.g.
      # `distinct seq[byte]` → `[]byte` rather than `""`).
      return nimTypeToGoCborHint(resolveUnderlyingType(t))
  ""

proc isGoCborMappable*(nimType: string): bool {.compileTime.} =
  nimTypeToGoCborHint(nimType).len > 0

proc goExportedField*(name: string): string {.compileTime.} =
  if name.len > 0 and name[0] >= 'a' and name[0] <= 'z':
    chr(ord(name[0]) - 32) & name[1 ..^ 1]
  else:
    name

const goReservedWords = [
  "break", "case", "chan", "const", "continue", "default", "defer", "else",
  "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map",
  "package", "range", "return", "select", "struct", "switch", "type", "var",
]

proc goSafeParam*(name: string): string {.compileTime.} =
  ## Returns a Go-legal local identifier — appends `Arg` suffix when the
  ## Nim parameter name collides with a Go reserved keyword (e.g.
  ## `range` → `rangeArg`, `type` → `typeArg`). The CBOR wire field is
  ## emitted from the original name, so wire compatibility is preserved.
  if name in goReservedWords:
    name & "Arg"
  else:
    name

proc snakeToPascal(name: string): string {.compileTime.} =
  ## Converts a snake_case identifier (CBOR apiName / event name) to
  ## PascalCase for Go method exports.
  result = ""
  var capitalize = true
  for ch in name:
    if ch == '_' or ch == '-':
      capitalize = true
    elif capitalize:
      result.add(
        if ch >= 'a' and ch <= 'z':
          chr(ord(ch) - 32)
        else:
          ch
      )
      capitalize = false
    else:
      result.add(ch)

proc goCborClassName(libName: string): string {.compileTime.} =
  result = ""
  var capitalize = true
  for ch in libName:
    if ch == '_' or ch == '-':
      capitalize = true
    elif capitalize:
      result.add(chr(ord(ch) - 32 * ord(ch in {'a' .. 'z'})))
      capitalize = false
    else:
      result.add(ch)

proc goCborPackageName(libName: string): string {.compileTime.} =
  result = ""
  for ch in libName:
    if ch != '_' and ch != '-':
      result.add(
        if ch >= 'A' and ch <= 'Z':
          chr(ord(ch) + 32)
        else:
          ch
      )

# ---------------------------------------------------------------------------
# File emission
# ---------------------------------------------------------------------------

{.pop.}

proc generateCborGoFile*(
    outDir: string,
    libName: string,
    requestEntries: seq[CborRequestEntry],
    eventEntries: seq[CborEventEntry],
) {.compileTime, raises: [].} =
  ## Emits `<outDir>/<libName>_go/{<libName>.go, <libName>_callbacks.c}`.
  ## Same filenames as the native generator — only one wrapper exists per
  ## build dir, so no build tags / no `_cbor` suffix.
  ensureGeneratedOutputDir(outDir)
  let modDir =
    if outDir.len > 0:
      outDir & "/" & libName & "_go"
    else:
      libName & "_go"
  ensureGeneratedOutputDir(modDir)

  let pkgName = goCborPackageName(libName)
  let className = goCborClassName(libName)
  let p = libName & "_"

  # ---------------------- go.mod ----------------------
  # Always emit go.mod with the cbor dependency. (If a native-only build
  # ran first and wrote go.mod without it, overwrite.)
  var goMod = "// Generated by nim-brokers Go FFI codegen — do not edit.\n"
  goMod.add("module " & libName & "\n\n")
  goMod.add("go 1.21\n\n")
  goMod.add("require github.com/fxamacker/cbor/v2 v2.7.0\n")
  try:
    writeFile(modDir & "/go.mod", goMod)
  except IOError:
    error("Failed to write go.mod: " & getCurrentExceptionMsg())

  # ---------------------- <libName>.go ----------------------
  var g = "// Generated by nim-brokers CBOR FFI Go codegen — do not edit.\n"
  g.add("//\n")
  g.add(
    "// CBOR-mode Go wrapper around the fixed 11-fn ABI declared by the `" & libName &
      "` shared library.\n"
  )
  g.add("//\n")
  g.add("// Public surface mirrors the native build:\n")
  g.add("//   " & libName & ".Version()\n")
  g.add("//   " & libName & ".New() + lib.CreateContext()\n")
  g.add("//   <Request>(args) -> (T, error)\n")
  g.add("//   On<Event>(callback) -> uint64 / Off<Event>(handle uint64)\n")
  g.add("//\n")
  for e in requestEntries:
    var sigParams = ""
    for i, (n, t) in e.argFields.pairs:
      if i > 0:
        sigParams.add(", ")
      let h = nimTypeToGoCborHint(t)
      sigParams.add(goExportedField(n) & " " & (if h.len > 0: h else: "any"))
    g.add(
      "//   " & snakeToPascal(e.apiName) & "(" & sigParams & ") (" & e.responseTypeName &
        ", error)\n"
    )
  for ev in eventEntries:
    g.add("//   On" & snakeToPascal(ev.apiName) & "(callback) uint64\n")
    g.add("//   Off" & snakeToPascal(ev.apiName) & "(handle uint64)\n")
  g.add("\n")

  g.add("package " & pkgName & "\n\n")

  # cgo prelude
  g.add("/*\n")
  g.add("#cgo CFLAGS: -I${SRCDIR}/..\n")
  g.add("#cgo LDFLAGS: -L${SRCDIR}/.. -l" & libName & "\n")
  g.add("#cgo darwin LDFLAGS: -Wl,-rpath,${SRCDIR}/..\n")
  g.add("#cgo linux LDFLAGS: -Wl,-rpath,${SRCDIR}/..\n")
  g.add("#include <stdlib.h>\n")
  g.add("#include <string.h>\n")
  g.add("#include <stdint.h>\n")
  g.add("#include \"" & libName & ".h\"\n")
  g.add(
    "uint64_t go_cbor_subscribe(uint32_t ctx, const char* name, void* user_data);\n"
  )
  g.add("*/\n")
  g.add("import \"C\"\n\n")

  g.add("import (\n")
  g.add("\t\"errors\"\n")
  g.add("\t\"runtime\"\n")
  g.add("\t\"runtime/cgo\"\n")
  g.add("\t\"sync\"\n")
  g.add("\t\"unsafe\"\n")
  g.add("\t\"github.com/fxamacker/cbor/v2\"\n")
  g.add(")\n\n")
  g.add("var _ = errors.New\n")
  g.add("var _ = runtime.SetFinalizer\n")
  g.add("var _ cgo.Handle\n")
  g.add("var _ sync.Mutex\n")
  g.add("var _ unsafe.Pointer\n")
  g.add("var _ = cbor.Marshal\n\n")

  # Per-context cgo.Handle registry — same UAF-safe pattern as native:
  # the closure stays alive across Off<Event> until Close() runs.
  g.add("var cborHandleReg = struct {\n")
  g.add("\tmu sync.Mutex\n")
  g.add("\tperCtx map[uint32][]cgo.Handle\n")
  g.add("}{perCtx: make(map[uint32][]cgo.Handle)}\n\n")
  g.add("func registerCborHandle(ctx C.uint32_t, h cgo.Handle) {\n")
  g.add("\tcborHandleReg.mu.Lock()\n")
  g.add(
    "\tcborHandleReg.perCtx[uint32(ctx)] = append(cborHandleReg.perCtx[uint32(ctx)], h)\n"
  )
  g.add("\tcborHandleReg.mu.Unlock()\n")
  g.add("}\n\n")
  g.add("func dropCborHandlesForCtx(ctx C.uint32_t) {\n")
  g.add("\tcborHandleReg.mu.Lock()\n")
  g.add("\thandles := cborHandleReg.perCtx[uint32(ctx)]\n")
  g.add("\tdelete(cborHandleReg.perCtx, uint32(ctx))\n")
  g.add("\tcborHandleReg.mu.Unlock()\n")
  g.add("\tfor _, h := range handles { h.Delete() }\n")
  g.add("}\n\n")

  # ---- Generated payload types ------------------------------------------
  var enumNames: seq[string] = @[]
  for entry in gApiTypeRegistry:
    if entry.kind == atkEnum:
      enumNames.add(entry.name)
  var aliasNames: seq[string] = @[]
  for entry in gApiTypeRegistry:
    if entry.kind in {atkDistinct, atkAlias}:
      aliasNames.add(entry.name)
  var objectNames: seq[string] = @[]
  for entry in gApiTypeRegistry:
    if entry.kind == atkObject and not entry.name.endsWith("CborArgs"):
      objectNames.add(entry.name)

  # A "scalar payload" is a primitive (non-object) broker type — `type X =
  # int32` — registered as a distinct alias of its underlying primitive.
  # Its CBOR wire value is a bare scalar; the Go surface uses the
  # `type X = <prim>` alias directly. Such a type has no object fields, so
  # the event handler delivers the bare value rather than unpacked fields.
  proc isScalarPayload(name: string): bool {.compileTime.} =
    name.len > 0 and isTypeRegistered(name) and
      lookupTypeEntry(name).kind in {atkAlias, atkDistinct} and
      primGoHint(resolveUnderlyingType(name)).len > 0

  if enumNames.len > 0 or aliasNames.len > 0 or objectNames.len > 0:
    g.add("// -------- Generated payload types --------\n\n")

  for name in enumNames:
    let entry = lookupTypeEntry(name)
    g.add("type " & name & " int32\n\n")
    g.add("const (\n")
    if entry.enumValues.len == 0:
      g.add("\t" & name & "_Unknown " & name & " = 0\n")
    else:
      for v in entry.enumValues:
        g.add("\t" & name & "_" & v.name & " " & name & " = " & $v.ordinal & "\n")
    g.add(")\n\n")

  for name in aliasNames:
    let underlying = resolveUnderlyingType(name)
    let goU = primGoHint(underlying)
    if goU.len == 0:
      g.add(
        "// TODO: alias '" & name & "' resolves to '" & underlying &
          "' (no Go primitive)\n\n"
      )
      continue
    g.add("type " & name & " = " & goU & "\n\n")

  for name in objectNames:
    let entry = lookupTypeEntry(name)
    g.add("type " & name & " struct {\n")
    var anyField = false
    for f in entry.fields:
      let hint = nimTypeToGoCborHint(f.nimType)
      if hint.len == 0:
        g.add("\t// TODO: Nim type '" & f.nimType & "' not yet mappable\n")
        continue
      let fx = goExportedField(f.name)
      g.add("\t" & fx & " " & hint & " `cbor:\"" & f.name & "\"`\n")
      anyField = true
    if not anyField:
      g.add("\t_ struct{}\n")
    g.add("}\n\n")

  # ---- Lib struct + event handler type -----------------------------------
  g.add("// -------- Event dispatch --------\n\n")
  g.add("// cborEventHandler is what we anchor on the Go side via cgo.NewHandle.\n")
  g.add("// Each subscription's user_data is the corresponding cgo.Handle, so\n")
  g.add("// the trampoline retrieves and invokes exactly that one closure per\n")
  g.add("// event emit — no global map, no fan-out, no cross-context leakage.\n")
  g.add("type cborEventHandler func([]byte)\n\n")

  g.add("// -------- Lib struct --------\n\n")
  g.add("type " & className & " struct {\n")
  g.add("\tctx C.uint32_t\n")
  g.add("\tmu  sync.Mutex\n")
  g.add("}\n\n")

  g.add("func Version() string {\n")
  g.add("\treturn C.GoString(C." & p & "version())\n")
  g.add("}\n\n")

  g.add("func New() *" & className & " {\n")
  g.add("\tC." & p & "initialize()\n")
  g.add("\tl := &" & className & "{}\n")
  g.add("\truntime.SetFinalizer(l, func(x *" & className & ") { x.Close() })\n")
  g.add("\treturn l\n")
  g.add("}\n\n")

  g.add("func (l *" & className & ") CreateContext() error {\n")
  g.add("\tl.mu.Lock()\n\tdefer l.mu.Unlock()\n")
  g.add("\tif l.ctx != 0 { return errors.New(\"context already created\") }\n")
  g.add("\tvar errPtr *C.char\n")
  g.add("\tctx := C." & p & "createContext(&errPtr)\n")
  g.add("\tif ctx == 0 {\n")
  g.add("\t\tmsg := \"createContext returned 0\"\n")
  g.add(
    "\t\tif errPtr != nil { msg = C.GoString(errPtr); C." & p &
      "freeBuffer(unsafe.Pointer(errPtr)) }\n"
  )
  g.add("\t\treturn errors.New(msg)\n")
  g.add("\t}\n")
  g.add("\tl.ctx = ctx\n")
  g.add("\treturn nil\n")
  g.add("}\n\n")

  g.add("func (l *" & className & ") ValidContext() bool { return l.ctx != 0 }\n")
  g.add("func (l *" & className & ") Ctx() uint32 { return uint32(l.ctx) }\n\n")

  g.add("func (l *" & className & ") Close() {\n")
  g.add("\tl.mu.Lock()\n\tdefer l.mu.Unlock()\n")
  g.add("\tif l.ctx != 0 {\n")
  g.add("\t\tC." & p & "shutdown(l.ctx)\n")
  g.add("\t\tdropCborHandlesForCtx(l.ctx)\n")
  g.add("\t\tl.ctx = 0\n")
  g.add("\t}\n")
  g.add("}\n\n")

  # ---- Internal call helper ----------------------------------------------
  g.add("// internalCborCall encodes args via CBOR, copies into a library-\n")
  g.add("// allocated buffer (the C ABI frees it), dispatches, and returns\n")
  g.add("// the response bytes (caller-side copy of a library-owned buffer).\n")
  g.add(
    "func (l *" & className &
      ") internalCborCall(apiName string, args interface{}) ([]byte, error) {\n"
  )
  g.add(
    "\tif l.ctx == 0 { return nil, errors.New(\"library context is not created\") }\n"
  )
  g.add("\tvar inBytes []byte\n")
  g.add("\tif args != nil {\n")
  g.add("\t\tvar err error\n")
  g.add("\t\tinBytes, err = cbor.Marshal(args)\n")
  g.add("\t\tif err != nil { return nil, err }\n")
  g.add("\t}\n")
  g.add("\tcName := C.CString(apiName)\n")
  g.add("\tdefer C.free(unsafe.Pointer(cName))\n")
  g.add("\t// The library expects an `<lib>_allocBuffer`-allocated input\n")
  g.add("\t// buffer that it can free. Copy the Go bytes into one.\n")
  g.add("\tvar inPtr unsafe.Pointer\n")
  g.add("\tif len(inBytes) > 0 {\n")
  g.add("\t\tinPtr = C." & p & "allocBuffer(C.int32_t(len(inBytes)))\n")
  g.add("\t\tif inPtr == nil { return nil, errors.New(\"allocBuffer failed\") }\n")
  g.add("\t\tC.memcpy(inPtr, unsafe.Pointer(&inBytes[0]), C.size_t(len(inBytes)))\n")
  g.add("\t}\n")
  g.add("\tvar outBuf unsafe.Pointer\n")
  g.add("\tvar outLen C.int32_t\n")
  g.add(
    "\trc := C." & p &
      "call(l.ctx, cName, inPtr, C.int32_t(len(inBytes)), &outBuf, &outLen)\n"
  )
  g.add("\tif rc != 0 {\n")
  g.add("\t\tif outBuf != nil { C." & p & "freeBuffer(outBuf) }\n")
  g.add("\t\treturn nil, errors.New(\"call returned non-zero\")\n")
  g.add("\t}\n")
  g.add("\tif outBuf == nil { return nil, nil }\n")
  g.add("\tout := C.GoBytes(outBuf, C.int(outLen))\n")
  g.add("\tC." & p & "freeBuffer(outBuf)\n")
  g.add("\treturn out, nil\n")
  g.add("}\n\n")

  # ---- Per-request methods ------------------------------------------------
  for e in requestEntries:
    let methodName = snakeToPascal(e.apiName)
    let respType = e.responseTypeName
    var argsStructFields = ""
    var argsAssign = ""
    var firstNonZero = false
    for (n, t) in e.argFields:
      let h = nimTypeToGoCborHint(t)
      let hType = if h.len > 0: h else: "any"
      let exN = goExportedField(n)
      # Param name stays lowercase (`n`) to avoid colliding with type
      # names (e.g. `priority Priority` is fine, `Priority Priority`
      # makes Go report "Priority is not a type" inside the args struct
      # because the parameter shadows the type in lookup).
      argsStructFields.add("\t\t" & exN & " " & hType & " `cbor:\"" & n & "\"`\n")
      argsAssign.add("\t\t" & exN & ": " & goSafeParam(n) & ",\n")
      firstNonZero = true
    g.add("func (l *" & className & ") " & methodName & "(")
    var firstP = true
    for (n, t) in e.argFields:
      let h = nimTypeToGoCborHint(t)
      let hType = if h.len > 0: h else: "any"
      if not firstP:
        g.add(", ")
      g.add(goSafeParam(n) & " " & hType)
      firstP = false
    g.add(") (" & respType & ", error) {\n")
    # `zeroResp` is the typed zero value for the error returns. Using a
    # declared var (not `RespType{}`) keeps it valid for scalar-payload
    # aliases too — `int32{}` would be a Go compile error.
    g.add("\tvar zeroResp " & respType & "\n")
    if firstNonZero:
      g.add("\targs := struct {\n")
      g.add(argsStructFields)
      g.add("\t}{\n")
      g.add(argsAssign)
      g.add("\t}\n")
      g.add("\tout, err := l.internalCborCall(\"" & e.apiName & "\", args)\n")
    else:
      g.add("\tout, err := l.internalCborCall(\"" & e.apiName & "\", nil)\n")
    g.add("\tif err != nil { return zeroResp, err }\n")
    g.add("\tvar env struct {\n")
    g.add("\t\tOk  *" & respType & " `cbor:\"ok\"`\n")
    g.add("\t\tErr *string `cbor:\"err\"`\n")
    g.add("\t}\n")
    g.add(
      "\tif derr := cbor.Unmarshal(out, &env); derr != nil { return zeroResp, derr }\n"
    )
    g.add("\tif env.Err != nil { return zeroResp, errors.New(*env.Err) }\n")
    g.add("\tif env.Ok != nil { return *env.Ok, nil }\n")
    g.add("\treturn zeroResp, errors.New(\"empty response envelope\")\n")
    g.add("}\n\n")

  # ---- Single CBOR event trampoline + per-event On/Off ---------------------
  if eventEntries.len > 0:
    g.add("// -------- CBOR event trampoline --------\n\n")
    g.add("//export goCborEventTrampoline\n")
    g.add(
      "func goCborEventTrampoline(ctx C.uint32_t, name *C.char, buf unsafe.Pointer, bufLen C.int32_t, ud unsafe.Pointer) {\n"
    )
    g.add("\t_ = ctx\n")
    g.add("\t_ = name\n")
    g.add("\tif ud == nil { return }\n")
    g.add("\tvar payload []byte\n")
    g.add("\tif buf != nil && bufLen > 0 {\n")
    g.add("\t\tpayload = C.GoBytes(buf, C.int(bufLen))\n")
    g.add("\t}\n")
    g.add("\th := cgo.Handle(uintptr(ud))\n")
    g.add("\tcb, ok := h.Value().(cborEventHandler)\n")
    g.add("\tif !ok { return }\n")
    g.add("\tcb(payload)\n")
    g.add("}\n\n")

  for ev in eventEntries:
    let exName = snakeToPascal(ev.apiName)
    let payloadType = ev.typeName
    # Walk the payload struct fields to build an unpacked-field handler
    # signature that matches the native build's `func(f1, f2, ...)` shape.
    var fieldNames: seq[string] = @[]
    var fieldGoTypes: seq[string] = @[]
    var fieldExNames: seq[string] = @[]
    var fieldsOk = true
    let scalarEvt = isScalarPayload(payloadType)
    if scalarEvt:
      # Scalar payload: the decoded `p` IS the value — one bare arg.
      fieldNames.add("value")
      fieldGoTypes.add(primGoHint(resolveUnderlyingType(payloadType)))
      fieldExNames.add("value")
    elif isTypeRegistered(payloadType):
      let entry = lookupTypeEntry(payloadType)
      for f in entry.fields:
        let h = nimTypeToGoCborHint(f.nimType)
        if h.len == 0:
          fieldsOk = false
          break
        fieldNames.add(f.name)
        fieldGoTypes.add(h)
        fieldExNames.add(goExportedField(f.name))
    else:
      fieldsOk = false

    if not fieldsOk:
      # Fall back to whole-struct callback if the payload has unmappable
      # fields (no native equivalent — both modes share the same gap).
      g.add(
        "// TODO(go-codegen-cbor): event '" & payloadType &
          "' has fields not yet mappable\n"
      )
      g.add(
        "func (l *" & className & ") On" & exName & "(cb func(" & payloadType &
          ")) uint64 { _ = cb; return 0 }\n\n"
      )
    else:
      var sig = ""
      for i in 0 ..< fieldNames.len:
        if i > 0:
          sig.add(", ")
        sig.add(fieldNames[i] & " " & fieldGoTypes[i])
      g.add(
        "func (l *" & className & ") On" & exName & "(cb func(" & sig & ")) uint64 {\n"
      )
      g.add("\tif l.ctx == 0 { return 0 }\n")
      g.add("\twrap := cborEventHandler(func(payload []byte) {\n")
      g.add("\t\tvar p " & payloadType & "\n")
      g.add("\t\tif derr := cbor.Unmarshal(payload, &p); derr != nil { return }\n")
      g.add("\t\tcb(")
      if scalarEvt:
        # Scalar payload: `p` IS the value — pass it directly.
        g.add("p")
      else:
        for i in 0 ..< fieldNames.len:
          if i > 0:
            g.add(", ")
          g.add("p." & fieldExNames[i])
      g.add(")\n")
      g.add("\t})\n")
      g.add("\th := cgo.NewHandle(wrap)\n")
      g.add("\tcName := C.CString(\"" & ev.apiName & "\")\n")
      g.add("\tdefer C.free(unsafe.Pointer(cName))\n")
      g.add(
        "\thandle := uint64(C.go_cbor_subscribe(l.ctx, cName, unsafe.Pointer(h)))\n"
      )
      g.add("\tif handle == 0 {\n")
      g.add("\t\th.Delete()\n")
      g.add("\t\treturn 0\n")
      g.add("\t}\n")
      g.add("\tregisterCborHandle(l.ctx, h)\n")
      g.add("\treturn handle\n")
      g.add("}\n\n")

    g.add("func (l *" & className & ") Off" & exName & "(handle uint64) {\n")
    g.add("\tif l.ctx == 0 { return }\n")
    g.add("\tcName := C.CString(\"" & ev.apiName & "\")\n")
    g.add("\tdefer C.free(unsafe.Pointer(cName))\n")
    g.add("\tC." & p & "unsubscribe(l.ctx, cName, C.uint64_t(handle))\n")
    g.add("}\n\n")

  try:
    writeFile(modDir & "/" & libName & ".go", g)
  except IOError:
    error("Failed to write CBOR Go file: " & getCurrentExceptionMsg())

  # ---------------------- <libName>_callbacks.c ----------------------
  if eventEntries.len > 0:
    var c = "// Generated by nim-brokers CBOR FFI Go codegen — do not edit.\n"
    c.add("#include <stdint.h>\n")
    c.add("#include <stdlib.h>\n")
    c.add("#include \"" & libName & ".h\"\n")
    c.add("#include \"_cgo_export.h\"\n\n")
    c.add(
      "uint64_t go_cbor_subscribe(uint32_t ctx, const char* name, void* user_data) {\n"
    )
    c.add(
      "    return " & p & "subscribe(ctx, name, (" & p &
        "event_cb_t)goCborEventTrampoline, user_data);\n"
    )
    c.add("}\n")
    try:
      writeFile(modDir & "/" & libName & "_callbacks.c", c)
    except IOError:
      error("Failed to write CBOR Go callbacks file: " & getCurrentExceptionMsg())

{.push raises: [].}
{.pop.}
