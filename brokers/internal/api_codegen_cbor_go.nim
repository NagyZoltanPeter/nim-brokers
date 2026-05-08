## CBOR-mode Go wrapper code generation.
##
## Mirrors `api_codegen_cbor_rust.nim` but emits idiomatic Go with
## `(T, error)` returns. Uses `github.com/fxamacker/cbor/v2` for
## CBOR encoding/decoding (struct tags map Nim camelCase wire keys to
## Go-style PascalCase fields).
##
## Native and CBOR mode produce two files in the same `<libname>_go/`
## directory, distinguished by Go build tags:
##   <libname>.go            //go:build !cbor   (step 1+2)
##   <libname>_cbor.go       //go:build cbor    (this file)
## A consumer chooses with `go build` / `go run -tags cbor ...`.

{.push raises: [].}

import std/[macros, strutils, tables]
import ./api_codegen_c, ./api_common, ./api_schema

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
      return primGoHint(resolveUnderlyingType(t))
  ""

proc isGoCborMappable*(nimType: string): bool {.compileTime.} =
  nimTypeToGoCborHint(nimType).len > 0

proc goExportedField*(name: string): string {.compileTime.} =
  if name.len > 0 and name[0] >= 'a' and name[0] <= 'z':
    chr(ord(name[0]) - 32) & name[1 ..^ 1]
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
      result.add(if ch >= 'a' and ch <= 'z': chr(ord(ch) - 32) else: ch)
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
      result.add(if ch >= 'A' and ch <= 'Z': chr(ord(ch) + 32) else: ch)

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
  ## Emits `<outDir>/<libName>_go/{<libName>_cbor.go, <libName>_cbor_callbacks.c}`
  ## guarded by `//go:build cbor`. The native pair lives alongside under
  ## `//go:build !cbor`, so a single module supports both modes.
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

  # ---------------------- <libName>_cbor.go ----------------------
  var g = "//go:build cbor\n\n"
  g.add("// Generated by nim-brokers CBOR FFI Go codegen — do not edit.\n")
  g.add("//\n")
  g.add(
    "// CBOR-mode Go wrapper around the fixed 11-fn ABI declared by the `" &
      libName & "` shared library.\n"
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
      "//   " & snakeToPascal(e.apiName) & "(" & sigParams & ") (" &
        e.responseTypeName & ", error)\n"
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
  g.add("uint64_t go_cbor_subscribe(uint32_t ctx, const char* name);\n")
  g.add("*/\n")
  g.add("import \"C\"\n\n")

  g.add("import (\n")
  g.add("\t\"errors\"\n")
  g.add("\t\"runtime\"\n")
  g.add("\t\"sync\"\n")
  g.add("\t\"unsafe\"\n")
  g.add("\t\"github.com/fxamacker/cbor/v2\"\n")
  g.add(")\n\n")
  g.add("var _ = errors.New\n")
  g.add("var _ = runtime.SetFinalizer\n")
  g.add("var _ sync.Mutex\n")
  g.add("var _ unsafe.Pointer\n")
  g.add("var _ = cbor.Marshal\n\n")

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
      g.add("// TODO: alias '" & name & "' resolves to '" & underlying & "' (no Go primitive)\n\n")
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

  # ---- Lib struct + event registry ---------------------------------------
  g.add("// -------- Event dispatch registry --------\n\n")
  g.add("type cborEventHandler func([]byte)\n\n")
  g.add("var cborEventReg = struct {\n")
  g.add("\tmu sync.Mutex\n")
  g.add("\t// Per (ctx, eventName) -> map[handle]handler.\n")
  g.add("\tbyCtx map[uint32]map[string]map[uint64]cborEventHandler\n")
  g.add("}{byCtx: make(map[uint32]map[string]map[uint64]cborEventHandler)}\n\n")

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
  g.add("\t\tif errPtr != nil { msg = C.GoString(errPtr); C." & p & "freeBuffer(unsafe.Pointer(errPtr)) }\n")
  g.add("\t\treturn errors.New(msg)\n")
  g.add("\t}\n")
  g.add("\tl.ctx = ctx\n")
  g.add("\tcborEventReg.mu.Lock()\n")
  g.add("\tcborEventReg.byCtx[uint32(ctx)] = make(map[string]map[uint64]cborEventHandler)\n")
  g.add("\tcborEventReg.mu.Unlock()\n")
  g.add("\treturn nil\n")
  g.add("}\n\n")

  g.add("func (l *" & className & ") ValidContext() bool { return l.ctx != 0 }\n")
  g.add("func (l *" & className & ") Ctx() uint32 { return uint32(l.ctx) }\n\n")

  g.add("func (l *" & className & ") Close() {\n")
  g.add("\tl.mu.Lock()\n\tdefer l.mu.Unlock()\n")
  g.add("\tif l.ctx != 0 {\n")
  g.add("\t\tC." & p & "shutdown(l.ctx)\n")
  g.add("\t\tcborEventReg.mu.Lock()\n")
  g.add("\t\tdelete(cborEventReg.byCtx, uint32(l.ctx))\n")
  g.add("\t\tcborEventReg.mu.Unlock()\n")
  g.add("\t\tl.ctx = 0\n")
  g.add("\t}\n")
  g.add("}\n\n")

  # ---- Internal call helper ----------------------------------------------
  g.add("// internalCborCall encodes args via CBOR, copies into a library-\n")
  g.add("// allocated buffer (the C ABI frees it), dispatches, and returns\n")
  g.add("// the response bytes (caller-side copy of a library-owned buffer).\n")
  g.add("func (l *" & className & ") internalCborCall(apiName string, args interface{}) ([]byte, error) {\n")
  g.add("\tif l.ctx == 0 { return nil, errors.New(\"library context is not created\") }\n")
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
  g.add("\trc := C." & p & "call(l.ctx, cName, inPtr, C.int32_t(len(inBytes)), &outBuf, &outLen)\n")
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
      argsAssign.add("\t\t" & exN & ": " & n & ",\n")
      firstNonZero = true
    g.add("func (l *" & className & ") " & methodName & "(")
    var firstP = true
    for (n, t) in e.argFields:
      let h = nimTypeToGoCborHint(t)
      let hType = if h.len > 0: h else: "any"
      if not firstP: g.add(", ")
      g.add(n & " " & hType)
      firstP = false
    g.add(") (" & respType & ", error) {\n")
    if firstNonZero:
      g.add("\targs := struct {\n")
      g.add(argsStructFields)
      g.add("\t}{\n")
      g.add(argsAssign)
      g.add("\t}\n")
      g.add("\tout, err := l.internalCborCall(\"" & e.apiName & "\", args)\n")
    else:
      g.add("\tout, err := l.internalCborCall(\"" & e.apiName & "\", nil)\n")
    g.add("\tif err != nil { return " & respType & "{}, err }\n")
    g.add("\tvar env struct {\n")
    g.add("\t\tOk  *" & respType & " `cbor:\"ok\"`\n")
    g.add("\t\tErr *string `cbor:\"err\"`\n")
    g.add("\t}\n")
    g.add("\tif derr := cbor.Unmarshal(out, &env); derr != nil { return " & respType & "{}, derr }\n")
    g.add("\tif env.Err != nil { return " & respType & "{}, errors.New(*env.Err) }\n")
    g.add("\tif env.Ok != nil { return *env.Ok, nil }\n")
    g.add("\treturn " & respType & "{}, errors.New(\"empty response envelope\")\n")
    g.add("}\n\n")

  # ---- Single CBOR event trampoline + per-event On/Off ---------------------
  if eventEntries.len > 0:
    g.add("// -------- CBOR event trampoline --------\n\n")
    g.add("//export goCborEventTrampoline\n")
    g.add(
      "func goCborEventTrampoline(ctx C.uint32_t, name *C.char, buf unsafe.Pointer, bufLen C.int32_t, _ud unsafe.Pointer) {\n"
    )
    g.add("\tif name == nil { return }\n")
    g.add("\tevName := C.GoString(name)\n")
    g.add("\tvar payload []byte\n")
    g.add("\tif buf != nil && bufLen > 0 {\n")
    g.add("\t\tpayload = C.GoBytes(buf, C.int(bufLen))\n")
    g.add("\t}\n")
    g.add("\tcborEventReg.mu.Lock()\n")
    g.add("\tperEvent, ok := cborEventReg.byCtx[uint32(ctx)]\n")
    g.add("\tif !ok { cborEventReg.mu.Unlock(); return }\n")
    g.add("\thandlers, ok := perEvent[evName]\n")
    g.add("\tif !ok || len(handlers) == 0 { cborEventReg.mu.Unlock(); return }\n")
    g.add("\tsnap := make([]cborEventHandler, 0, len(handlers))\n")
    g.add("\tfor _, h := range handlers { snap = append(snap, h) }\n")
    g.add("\tcborEventReg.mu.Unlock()\n")
    g.add("\tfor _, h := range snap { h(payload) }\n")
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
    if isTypeRegistered(payloadType):
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
      g.add("// TODO(go-codegen-cbor): event '" & payloadType & "' has fields not yet mappable\n")
      g.add("func (l *" & className & ") On" & exName & "(cb func(" & payloadType & ")) uint64 { _ = cb; return 0 }\n\n")
    else:
      var sig = ""
      for i in 0 ..< fieldNames.len:
        if i > 0: sig.add(", ")
        sig.add(fieldNames[i] & " " & fieldGoTypes[i])
      g.add("func (l *" & className & ") On" & exName & "(cb func(" & sig & ")) uint64 {\n")
      g.add("\tif l.ctx == 0 { return 0 }\n")
      g.add("\tcName := C.CString(\"" & ev.apiName & "\")\n")
      g.add("\tdefer C.free(unsafe.Pointer(cName))\n")
      g.add("\thandle := uint64(C.go_cbor_subscribe(l.ctx, cName))\n")
      g.add("\tif handle == 0 { return 0 }\n")
      g.add("\twrap := func(payload []byte) {\n")
      g.add("\t\tvar p " & payloadType & "\n")
      g.add("\t\tif derr := cbor.Unmarshal(payload, &p); derr != nil { return }\n")
      g.add("\t\tcb(")
      for i in 0 ..< fieldNames.len:
        if i > 0: g.add(", ")
        g.add("p." & fieldExNames[i])
      g.add(")\n")
      g.add("\t}\n")
      g.add("\tcborEventReg.mu.Lock()\n")
      g.add("\tperEvent, ok := cborEventReg.byCtx[uint32(l.ctx)]\n")
      g.add("\tif !ok { perEvent = make(map[string]map[uint64]cborEventHandler); cborEventReg.byCtx[uint32(l.ctx)] = perEvent }\n")
      g.add("\thandlers, ok := perEvent[\"" & ev.apiName & "\"]\n")
      g.add("\tif !ok { handlers = make(map[uint64]cborEventHandler); perEvent[\"" & ev.apiName & "\"] = handlers }\n")
      g.add("\thandlers[handle] = wrap\n")
      g.add("\tcborEventReg.mu.Unlock()\n")
      g.add("\treturn handle\n")
      g.add("}\n\n")

    g.add("func (l *" & className & ") Off" & exName & "(handle uint64) {\n")
    g.add("\tif l.ctx == 0 { return }\n")
    g.add("\tcName := C.CString(\"" & ev.apiName & "\")\n")
    g.add("\tdefer C.free(unsafe.Pointer(cName))\n")
    g.add("\tC." & p & "unsubscribe(l.ctx, cName, C.uint64_t(handle))\n")
    g.add("\tcborEventReg.mu.Lock()\n")
    g.add("\tdefer cborEventReg.mu.Unlock()\n")
    g.add("\tif perEvent, ok := cborEventReg.byCtx[uint32(l.ctx)]; ok {\n")
    g.add("\t\tif handlers, ok := perEvent[\"" & ev.apiName & "\"]; ok {\n")
    g.add("\t\t\tif handle == 0 { delete(perEvent, \"" & ev.apiName & "\") } else { delete(handlers, handle) }\n")
    g.add("\t\t}\n")
    g.add("\t}\n")
    g.add("}\n\n")

  try:
    writeFile(modDir & "/" & libName & "_cbor.go", g)
  except IOError:
    error("Failed to write CBOR Go file: " & getCurrentExceptionMsg())

  # ---------------------- <libName>_cbor_callbacks.c ----------------------
  if eventEntries.len > 0:
    var c = "// +build cbor\n\n"
    c.add("// Generated by nim-brokers CBOR FFI Go codegen — do not edit.\n")
    c.add("#include <stdint.h>\n")
    c.add("#include <stdlib.h>\n")
    c.add("#include \"" & libName & ".h\"\n")
    c.add("#include \"_cgo_export.h\"\n\n")
    c.add("uint64_t go_cbor_subscribe(uint32_t ctx, const char* name) {\n")
    c.add("    return " & p & "subscribe(ctx, name, (" & p & "event_cb_t)goCborEventTrampoline, NULL);\n")
    c.add("}\n")
    try:
      writeFile(modDir & "/" & libName & "_cbor_callbacks.c", c)
    except IOError:
      error("Failed to write CBOR Go callbacks file: " & getCurrentExceptionMsg())

{.push raises: [].}
{.pop.}
