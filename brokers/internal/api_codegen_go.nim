## api_codegen_go
## --------------
## Go wrapper code generation for the FFI API system (native mode).
##
## Mirrors `api_codegen_rust.nim` 1:1: type-mapping procs, compile-time
## accumulators populated by request/event broker codegens, and a
## `generateGoFile` proc that writes a single flat Go module
## (`<outDir>/<libName>_go/{go.mod, <libName>.go}`).
##
## The generated module declares the C ABI via cgo (no bindgen) and
## exposes a high-level `Lib` struct with `(T, error)`-returning request
## methods, `On<Event>` / `Off<Event>` registration helpers, and a
## `Close()` method that calls `<lib>_shutdown` — same shape as the
## C++/Rust wrappers, in idiomatic Go.

{.push raises: [].}

import std/[macros, strutils]
import ./api_codegen_c

export api_codegen_c

# ---------------------------------------------------------------------------
# Compile-time Nim → Go type mapping
# ---------------------------------------------------------------------------

proc nimTypeToGo*(nimType: NimNode): string {.compileTime.} =
  ## Maps a Nim type to its safe-side Go type (used in struct fields and
  ## public method signatures).
  case nimType.kind
  of nnkIdent:
    let name = ($nimType).toLowerAscii()
    case name
    of "int", "int32":
      "int32"
    of "int8":
      "int8"
    of "int16":
      "int16"
    of "int64":
      "int64"
    of "uint", "uint32":
      "uint32"
    of "uint8", "byte":
      "byte"
    of "uint16":
      "uint16"
    of "uint64":
      "uint64"
    of "float", "float64":
      "float64"
    of "float32":
      "float32"
    of "bool":
      "bool"
    of "string", "cstring":
      "string"
    of "brokercontext":
      "uint32"
    of "pointer":
      "unsafe.Pointer"
    else:
      if isEnumRegistered($nimType):
        $nimType
      elif isAliasOrDistinctRegistered($nimType):
        nimTypeToGo(ident(resolveUnderlyingType($nimType)))
      else:
        $nimType # user-defined struct
  of nnkBracketExpr:
    if isSeqType(nimType):
      let elemName = seqItemTypeName(nimType)
      "[]" & nimTypeToGo(ident(elemName))
    elif isArrayTypeNode(nimType):
      let elemName = arrayNodeElemName(nimType)
      "[]" & nimTypeToGo(ident(elemName))
    else:
      "interface{}"
  else:
    "interface{}"

proc nimTypeToGoCgo*(nimType: NimNode): string {.compileTime.} =
  ## Maps a Nim type to its cgo-compatible Go type (the `C.<...>` form
  ## used in extern declarations and struct fields read from C memory).
  ## Used inside Go code where `C.` types are visible.
  case nimType.kind
  of nnkIdent:
    let name = ($nimType).toLowerAscii()
    case name
    of "int", "int32":
      "C.int32_t"
    of "int8":
      "C.int8_t"
    of "int16":
      "C.int16_t"
    of "int64":
      "C.int64_t"
    of "uint", "uint32":
      "C.uint32_t"
    of "uint8", "byte":
      "C.uint8_t"
    of "uint16":
      "C.uint16_t"
    of "uint64":
      "C.uint64_t"
    of "float", "float64":
      "C.double"
    of "float32":
      "C.float"
    of "bool":
      "C.bool"
    of "string", "cstring":
      "*C.char"
    of "brokercontext":
      "C.uint32_t"
    of "pointer":
      "unsafe.Pointer"
    else:
      if isEnumRegistered($nimType):
        "C.int32_t"
      elif isAliasOrDistinctRegistered($nimType):
        nimTypeToGoCgo(ident(resolveUnderlyingType($nimType)))
      else:
        "C." & $nimType & "CItem"
  of nnkBracketExpr:
    if isSeqType(nimType):
      "unsafe.Pointer"
    elif isArrayTypeNode(nimType):
      let elemName = arrayNodeElemName(nimType)
      "*" & nimTypeToGoCgo(ident(elemName))
    else:
      "unsafe.Pointer"
  else:
    "unsafe.Pointer"

proc nimTypeToGoZero*(nimType: NimNode): string {.compileTime.} =
  ## Returns a Go zero-value expression for a struct field's safe Go
  ## type. Used when initializing result structs.
  case nimType.kind
  of nnkIdent:
    let name = ($nimType).toLowerAscii()
    case name
    of "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32",
        "uint64", "byte", "brokercontext":
      "0"
    of "float", "float32", "float64":
      "0"
    of "bool":
      "false"
    of "string", "cstring":
      "\"\""
    of "pointer":
      "nil"
    else:
      if isEnumRegistered($nimType):
        $nimType & "(0)"
      elif isAliasOrDistinctRegistered($nimType):
        nimTypeToGoZero(ident(resolveUnderlyingType($nimType)))
      else:
        $nimType & "{}"
  of nnkBracketExpr:
    if isSeqType(nimType) or isArrayTypeNode(nimType):
      "nil"
    else:
      "nil"
  else:
    "nil"

# ---------------------------------------------------------------------------
# Compile-time accumulators
# ---------------------------------------------------------------------------

var gApiGoEnums* {.compileTime.}: seq[string] =
  @[] ## Go enum (typed-int + iota) and alias/distinct typedef definitions.

var gApiGoStructs* {.compileTime.}: seq[string] =
  @[] ## Go struct definitions for object types and request results.

var gApiGoMethods* {.compileTime.}: seq[string] =
  @[] ## Go wrapper method definitions (request entry points).

var gApiGoEventMethods* {.compileTime.}: seq[string] =
  @[] ## Go wrapper On<Event>/Off<Event> method definitions.

var gApiGoExports* {.compileTime.}: seq[string] =
  @[] ## //export'd Go callback trampolines (for cgo C->Go calls).

var gApiGoEventCAdapters* {.compileTime.}: seq[string] =
  @[] ## Forward declarations of the per-event register helpers.
      ## Goes into the cgo C prelude (visible from Go).

var gApiGoEventCAdapterImpls* {.compileTime.}: seq[string] =
  @[] ## Bodies of the per-event register helpers, written into a
      ## separate `<libname>_callbacks.c` alongside the .go file. That .c
      ## file `#include`s `_cgo_export.h` so it can use cgo's typed extern
      ## declarations for the //export'd Go trampolines, avoiding the
      ## "conflicting types" error you'd hit declaring them in the prelude.

var gApiGoEventDispatchers* {.compileTime.}: seq[string] =
  @[] ## Per-event Go dispatcher: handler type alias + map[uint64]Handler
      ## + sync.Mutex. Snapshot-and-fan-out pattern (mirrors Rust).

var gApiGoExternFns* {.compileTime.}: seq[string] =
  @[] ## Lines documenting C functions referenced (used as a sanity log).

var gApiGoInterfaceSummary* {.compileTime.}: seq[string] =
  @[] ## Dense interface summary lines (rendered as a doc comment block).

# ---------------------------------------------------------------------------
# File emission
# ---------------------------------------------------------------------------

{.pop.}

proc goPackageName(libName: string): string {.compileTime.} =
  ## Go package names are lowercase, no underscores ideally. Use the lib
  ## name lowercased with underscores stripped.
  result = ""
  for ch in libName:
    if ch != '_' and ch != '-':
      result.add(if ch >= 'A' and ch <= 'Z': chr(ord(ch) + 32) else: ch)

proc goExportClassName(libName: string): string {.compileTime.} =
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

proc generateGoFile*(outDir: string, libName: string) {.compileTime, raises: [].} =
  ## Writes the accumulated Go wrapper module (go.mod + <libName>.go)
  ## under `<outDir>/<libName>_go/`.
  ensureGeneratedOutputDir(outDir)
  let modDir =
    if outDir.len > 0:
      outDir & "/" & libName & "_go"
    else:
      libName & "_go"
  ensureGeneratedOutputDir(modDir)

  let pkgName = goPackageName(libName)
  let className = goExportClassName(libName)
  let apiPrefix = libName & "_"

  # ---------------------- go.mod ----------------------
  var goMod = "// Generated by nim-brokers Go FFI codegen — do not edit.\n"
  goMod.add("module " & libName & "\n\n")
  goMod.add("go 1.21\n")
  try:
    writeFile(modDir & "/go.mod", goMod)
  except IOError:
    error(
      "Failed to write generated Go go.mod '" & modDir & "/go.mod': " &
        getCurrentExceptionMsg()
    )

  # ---------------------- <libName>.go ----------------------
  # Native-mode file. Excluded from `cbor` build-tag builds so consumers
  # can switch between native and CBOR with `go build -tags cbor`.
  var g = "//go:build !cbor\n\n"
  g.add("// Generated by nim-brokers Go FFI codegen — do not edit.\n")
  g.add("//\n")
  g.add(
    "// Idiomatic Go wrapper around the C ABI declared by the `" & libName &
      "` shared library.\n"
  )
  g.add("// Mirrors the public surface of the C++ and Rust wrappers:\n")
  g.add("//   - `(T, error)` envelope for every request method.\n")
  g.add("//   - `On<Event>` / `Off<Event>` registration helpers.\n")
  g.add("//   - `Close()` calls `" & libName & "_shutdown` (RAII via finalizer).\n")
  g.add("//\n")
  for line in gApiGoInterfaceSummary:
    g.add("// " & line & "\n")
  g.add("\n")

  g.add("package " & pkgName & "\n\n")

  # cgo prelude. Path defaults to current dir; consumer can override via
  # CGO_CFLAGS / CGO_LDFLAGS env vars at build time. The example crate
  # uses a build.go-style `// #cgo CFLAGS:` directive set by the consumer.
  # The shared library and its C header are emitted in the parent
  # directory of <libName>_go/, so cgo paths reach up one level.
  g.add("/*\n")
  g.add("#cgo CFLAGS: -I${SRCDIR}/..\n")
  g.add("#cgo LDFLAGS: -L${SRCDIR}/.. -l" & libName & "\n")
  g.add("#cgo darwin LDFLAGS: -Wl,-rpath,${SRCDIR}/..\n")
  g.add("#cgo linux LDFLAGS: -Wl,-rpath,${SRCDIR}/..\n")
  g.add("#include <stdlib.h>\n")
  g.add("#include <string.h>\n")
  g.add("#include <stdint.h>\n")
  g.add("#include \"" & libName & ".h\"\n")
  # Forward-declare the per-event register helpers. Their bodies live in
  # <libName>_callbacks.c so they can include <_cgo_export.h> to get
  # cgo's typed extern declarations for the //export'd Go trampolines.
  for line in gApiGoEventCAdapters:
    g.add(line.replace(ApiLibPrefixPlaceholder, apiPrefix))
    g.add("\n")
  g.add("*/\n")
  g.add("import \"C\"\n\n")

  g.add("import (\n")
  g.add("\t\"errors\"\n")
  g.add("\t\"runtime\"\n")
  g.add("\t\"sync\"\n")
  g.add("\t\"unsafe\"\n")
  g.add(")\n\n")

  g.add("// silence unused-import warnings if some imports aren't used by codegen.\n")
  g.add("var _ = errors.New\n")
  g.add("var _ = runtime.SetFinalizer\n")
  g.add("var _ sync.Mutex\n")
  g.add("var _ unsafe.Pointer\n\n")

  # ---- Enums and aliases ------------------------------------------------
  if gApiGoEnums.len > 0:
    g.add("// -------- Enums and type aliases --------\n\n")
    for td in gApiGoEnums:
      g.add(td)
      g.add("\n\n")

  # ---- Object structs ---------------------------------------------------
  if gApiGoStructs.len > 0:
    g.add("// -------- Result and object types --------\n\n")
    for s in gApiGoStructs:
      g.add(s)
      g.add("\n\n")

  # ---- Lib struct -------------------------------------------------------
  g.add("// " & className & " is the high-level handle for the `" & libName & "` library.\n")
  g.add("type " & className & " struct {\n")
  g.add("\tctx C.uint32_t\n")
  g.add("\tmu  sync.Mutex\n")
  g.add("}\n\n")

  g.add("// Version returns the static semver string baked into the shared library.\n")
  g.add("func Version() string {\n")
  g.add("\treturn C.GoString(C." & apiPrefix & "version())\n")
  g.add("}\n\n")

  g.add("// New constructs a new wrapper. Call CreateContext before any request method.\n")
  g.add("func New() *" & className & " {\n")
  g.add("\tl := &" & className & "{}\n")
  g.add("\truntime.SetFinalizer(l, func(x *" & className & ") { x.Close() })\n")
  g.add("\treturn l\n")
  g.add("}\n\n")

  g.add("// CreateContext allocates the underlying library context.\n")
  g.add("func (l *" & className & ") CreateContext() error {\n")
  g.add("\tl.mu.Lock()\n")
  g.add("\tdefer l.mu.Unlock()\n")
  g.add("\tif l.ctx != 0 {\n")
  g.add("\t\treturn errors.New(\"context already created\")\n")
  g.add("\t}\n")
  g.add("\tr := C." & apiPrefix & "createContext()\n")
  g.add("\tif r.error_message != nil {\n")
  g.add("\t\tmsg := C.GoString(r.error_message)\n")
  g.add("\t\tC.free_" & libName & "_create_context_result(&r)\n")
  g.add("\t\treturn errors.New(msg)\n")
  g.add("\t}\n")
  g.add("\tl.ctx = r.ctx\n")
  g.add("\tC.free_" & libName & "_create_context_result(&r)\n")
  g.add("\tif l.ctx == 0 {\n")
  g.add("\t\treturn errors.New(\"library context creation failed\")\n")
  g.add("\t}\n")
  g.add("\treturn nil\n")
  g.add("}\n\n")

  g.add("// ValidContext reports whether CreateContext has been called successfully.\n")
  g.add("func (l *" & className & ") ValidContext() bool { return l.ctx != 0 }\n\n")

  g.add("// Ctx returns the raw context id (for diagnostics).\n")
  g.add("func (l *" & className & ") Ctx() uint32 { return uint32(l.ctx) }\n\n")

  g.add("// Close tears down the library context. Idempotent.\n")
  g.add("func (l *" & className & ") Close() {\n")
  g.add("\tl.mu.Lock()\n")
  g.add("\tdefer l.mu.Unlock()\n")
  g.add("\tif l.ctx != 0 {\n")
  g.add("\t\tC." & apiPrefix & "shutdown(l.ctx)\n")
  g.add("\t\tl.ctx = 0\n")
  g.add("\t}\n")
  g.add("}\n\n")

  # ---- Request methods --------------------------------------------------
  for m in gApiGoMethods:
    g.add(
      m.replace("__LIB_OWNER_CLASS__", className).replace(
        ApiLibPrefixPlaceholder, apiPrefix
      )
    )
    g.add("\n\n")

  # ---- Event methods ----------------------------------------------------
  for m in gApiGoEventMethods:
    g.add(
      m.replace("__LIB_OWNER_CLASS__", className).replace(
        ApiLibPrefixPlaceholder, apiPrefix
      )
    )
    g.add("\n\n")

  # ---- Per-event dispatcher maps + handler type aliases ---------------
  if gApiGoEventDispatchers.len > 0:
    g.add("// -------- Event dispatchers --------\n\n")
    for d in gApiGoEventDispatchers:
      g.add(d.replace(ApiLibPrefixPlaceholder, apiPrefix))
      g.add("\n\n")

  # ---- //export trampolines (one per event, see api_event_broker hook) -
  for ex in gApiGoExports:
    g.add(ex.replace(ApiLibPrefixPlaceholder, apiPrefix))
    g.add("\n\n")

  try:
    writeFile(modDir & "/" & libName & ".go", g)
  except IOError:
    error(
      "Failed to write generated Go source '" & modDir & "/" & libName & ".go': " &
        getCurrentExceptionMsg()
    )

  # ---------------------- <libName>_callbacks.c ----------------------
  # Per-event register helpers — defined in a separate .c file so they
  # can include `_cgo_export.h` and see cgo's typed declarations of the
  # //export'd Go trampolines. The forward decls in the .go file's cgo
  # prelude give the Go side a callable handle (`C.go_register_<Evt>`).
  if gApiGoEventCAdapterImpls.len > 0:
    # Native-mode companion C file. The `// +build !cbor` constraint
    # mirrors the `//go:build !cbor` on <libName>.go so cgo only links
    # this file in native builds.
    var c = "// +build !cbor\n\n"
    c.add("// Generated by nim-brokers Go FFI codegen — do not edit.\n")
    c.add("// Companion C file for the cgo wrapper. Compiled together with\n")
    c.add("// " & libName & ".go by the Go toolchain.\n\n")
    c.add("#include <stdint.h>\n")
    c.add("#include <stdlib.h>\n")
    c.add("#include \"" & libName & ".h\"\n")
    c.add("#include \"_cgo_export.h\"\n\n")
    for impl in gApiGoEventCAdapterImpls:
      c.add(impl.replace(ApiLibPrefixPlaceholder, apiPrefix))
      c.add("\n")
    try:
      writeFile(modDir & "/" & libName & "_callbacks.c", c)
    except IOError:
      error(
        "Failed to write generated Go callbacks file '" & modDir & "/" & libName &
          "_callbacks.c': " & getCurrentExceptionMsg()
      )

{.push raises: [].}
{.pop.}
