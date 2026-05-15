## api_codegen_rust
## ----------------
## Rust wrapper code generation for the FFI API system (native mode).
##
## Mirrors `api_codegen_python.nim` 1:1: type-mapping procs, compile-time
## accumulators populated by request/event broker codegens, and a
## `generateRustFile` proc that writes a complete Cargo crate
## (`<outDir>/<libName>_rs/{Cargo.toml, src/lib.rs}`).
##
## The generated crate declares the C ABI as `extern "C"` blocks (no
## bindgen / no clang dependency) and exposes a safe `pub struct <Lib>`
## with `Result<T, String>` returning request methods, `on_<event>` /
## `off_<event>` registration helpers, and a `Drop` impl that calls
## `<lib>_shutdown` — the same shape as the C++ wrapper class.

{.push raises: [].}

import std/[macros, strutils]
import ./api_codegen_c

export api_codegen_c

# ---------------------------------------------------------------------------
# Compile-time Nim → Rust type mapping
# ---------------------------------------------------------------------------

proc nimTypeToRust*(nimType: NimNode): string {.compileTime.} =
  ## Maps a Nim type to its safe-side Rust type (used in struct fields and
  ## public method signatures).
  case nimType.kind
  of nnkIdent:
    let name = ($nimType).toLowerAscii()
    case name
    of "int", "int32":
      "i32"
    of "int8":
      "i8"
    of "int16":
      "i16"
    of "int64":
      "i64"
    of "uint", "uint32":
      "u32"
    of "uint8", "byte":
      "u8"
    of "uint16":
      "u16"
    of "uint64":
      "u64"
    of "float", "float64":
      "f64"
    of "float32":
      "f32"
    of "bool":
      "bool"
    of "string", "cstring":
      "String"
    of "brokercontext":
      "u32"
    of "pointer":
      "*mut ::std::ffi::c_void"
    else:
      if isEnumRegistered($nimType):
        $nimType
      elif isAliasOrDistinctRegistered($nimType):
        nimTypeToRust(ident(resolveUnderlyingType($nimType)))
      else:
        $nimType # user-defined struct
  of nnkBracketExpr:
    if isSeqType(nimType):
      let elemName = seqItemTypeName(nimType)
      "Vec<" & nimTypeToRust(ident(elemName)) & ">"
    elif isArrayTypeNode(nimType):
      let elemName = arrayNodeElemName(nimType)
      "Vec<" & nimTypeToRust(ident(elemName)) & ">"
    elif isOptionType(nimType):
      "Option<" & nimTypeToRust(optionInnerType(nimType)) & ">"
    else:
      "()"
  else:
    "()"

proc nimTypeToRustFfi*(nimType: NimNode): string {.compileTime.} =
  ## Maps a Nim type to its `extern "C"`-compatible Rust type. Strings
  ## become `*const c_char`, pointers stay raw, scalars match exactly.
  case nimType.kind
  of nnkIdent:
    let name = ($nimType).toLowerAscii()
    case name
    of "int", "int32":
      "i32"
    of "int8":
      "i8"
    of "int16":
      "i16"
    of "int64":
      "i64"
    of "uint", "uint32":
      "u32"
    of "uint8", "byte":
      "u8"
    of "uint16":
      "u16"
    of "uint64":
      "u64"
    of "float", "float64":
      "f64"
    of "float32":
      "f32"
    of "bool":
      "bool"
    of "string", "cstring":
      "*const ::std::os::raw::c_char"
    of "brokercontext":
      "u32"
    of "pointer":
      "*mut ::std::ffi::c_void"
    else:
      if isEnumRegistered($nimType):
        "i32"
      elif isAliasOrDistinctRegistered($nimType):
        nimTypeToRustFfi(ident(resolveUnderlyingType($nimType)))
      else:
        $nimType & "CItem"
  of nnkBracketExpr:
    if isSeqType(nimType):
      "*mut ::std::ffi::c_void"
    elif isArrayTypeNode(nimType):
      let elemName = arrayNodeElemName(nimType)
      "*const " & nimTypeToRustFfi(ident(elemName))
    elif isOptionType(nimType):
      # Option[T] expands to two FFI fields; this returns the type for
      # the value side. The companion `<name>_has_value: bool` is
      # appended by the FFI struct builder.
      nimTypeToRustFfi(optionInnerType(nimType))
    else:
      "*mut ::std::ffi::c_void"
  else:
    "*mut ::std::ffi::c_void"

proc nimTypeToRustDefault*(nimType: NimNode): string {.compileTime.} =
  ## Returns a Rust default value expression for a struct field.
  case nimType.kind
  of nnkIdent:
    let name = ($nimType).toLowerAscii()
    case name
    of "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32",
        "uint64", "byte", "brokercontext":
      "0"
    of "float", "float32", "float64":
      "0.0"
    of "bool":
      "false"
    of "string", "cstring":
      "String::new()"
    of "pointer":
      "::std::ptr::null_mut()"
    else:
      if isEnumRegistered($nimType) or isAliasOrDistinctRegistered($nimType):
        "Default::default()"
      else:
        "Default::default()"
  of nnkBracketExpr:
    if isSeqType(nimType) or isArrayTypeNode(nimType):
      "Vec::new()"
    else:
      "Default::default()"
  else:
    "Default::default()"

# ---------------------------------------------------------------------------
# Compile-time accumulators
# ---------------------------------------------------------------------------

var gApiRustEnums* {.compileTime.}: seq[string] =
  @[] ## Rust enum/typedef definitions (atkEnum / atkAlias / atkDistinct).

var gApiRustFfiStructs* {.compileTime.}: seq[string] =
  @[] ## #[repr(C)] FFI struct definitions (CItem and CResult types).

var gApiRustStructs* {.compileTime.}: seq[string] =
  @[] ## Safe-side Rust struct definitions (high-level result/item types).

var gApiRustMethods* {.compileTime.}: seq[string] =
  @[] ## Rust wrapper impl-block methods (request entry points).

var gApiRustEventMethods* {.compileTime.}: seq[string] =
  @[] ## Rust wrapper impl-block on_<name> / off_<name> methods.

var gApiRustExternFns* {.compileTime.}: seq[string] =
  @[] ## extern "C" function signatures (one per generated FFI function).

var gApiRustEventCbAliases* {.compileTime.}: seq[string] =
  @[] ## Per-event callback type aliases (extern "C" fn pointer types).

var gApiRustEventCbStorage* {.compileTime.}: seq[string] =
  @[] ## Field declarations on the wrapper for storing live callbacks.

var gApiRustInterfaceSummary* {.compileTime.}: seq[string] =
  @[] ## Dense interface summary lines (rendered as a doc comment block).

# ---------------------------------------------------------------------------
# File emission
# ---------------------------------------------------------------------------

{.pop.}

proc rustClassName(libName: string): string {.compileTime.} =
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

proc generateRustFile*(outDir: string, libName: string) {.compileTime, raises: [].} =
  ## Writes the accumulated Rust wrapper crate (Cargo.toml + src/lib.rs)
  ## under `<outDir>/<libName>_rs/`.
  ensureGeneratedOutputDir(outDir)
  let crateDir =
    if outDir.len > 0:
      outDir & "/" & libName & "_rs"
    else:
      libName & "_rs"
  let srcDir = crateDir & "/src"
  ensureGeneratedOutputDir(crateDir)
  ensureGeneratedOutputDir(srcDir)

  let className = rustClassName(libName)
  let apiPrefix = libName & "_"

  # ---------------------- Cargo.toml ----------------------
  var cargo = "# Generated by nim-brokers Rust FFI codegen — do not edit.\n"
  cargo.add("[package]\n")
  cargo.add("name = \"" & libName & "\"\n")
  cargo.add("version = \"0.1.0\"\n")
  cargo.add("edition = \"2021\"\n")
  cargo.add("rust-version = \"1.75\"\n\n")
  cargo.add("[lib]\n")
  cargo.add("name = \"" & libName & "\"\n")
  cargo.add("crate-type = [\"rlib\"]\n\n")
  cargo.add("[dependencies]\n")
  try:
    writeFile(crateDir & "/Cargo.toml", cargo)
  except IOError:
    error(
      "Failed to write generated Rust Cargo.toml '" & crateDir & "/Cargo.toml': " &
        getCurrentExceptionMsg()
    )

  # ---------------------- src/lib.rs ----------------------
  var rs = "// Generated by nim-brokers Rust FFI codegen — do not edit.\n"
  rs.add("//\n")
  rs.add(
    "// Safe Rust wrapper around the C ABI declared by the `" & libName &
      "` shared library.\n"
  )
  rs.add("// Mirrors the public surface of the generated C++ wrapper:\n")
  rs.add("//   - `Result<T, String>` envelope for every request method.\n")
  rs.add("//   - `on_<event>` / `off_<event>` registration helpers.\n")
  rs.add("//   - `Drop` impl calls `" & libName & "_shutdown`.\n")
  rs.add("//\n")
  for line in gApiRustInterfaceSummary:
    rs.add("// " & line & "\n")
  rs.add("\n")
  rs.add("#![allow(non_camel_case_types)]\n")
  rs.add("#![allow(non_snake_case)]\n")
  rs.add("#![allow(non_upper_case_globals)]\n")
  rs.add("#![allow(dead_code)]\n")
  rs.add("#![allow(unused_imports)]\n")
  rs.add("#![allow(clippy::missing_safety_doc)]\n\n")

  rs.add("use std::ffi::{CStr, CString};\n")
  rs.add("use std::os::raw::{c_char, c_int, c_void};\n")
  rs.add("use std::sync::{Mutex, OnceLock};\n\n")

  # Central event-holder registry — tracks the Box<Arc<closure>> pointers
  # leaked by every on_X registration so Drop can free them all when a
  # context shuts down. We deliberately keep them alive across off_X
  # calls so in-flight callbacks (which the broker docs say complete
  # after off_X returns) don't UAF.
  rs.add("type EventHolderDropper = fn(*mut c_void);\n")
  rs.add(
    "struct EventHolderEntry { ctx: u32, ptr: *mut c_void, dropper: EventHolderDropper }\n"
  )
  rs.add("// Send/Sync OK: the raw pointer points at a heap-allocated\n")
  rs.add("// Arc<dyn Fn(..) + Send + Sync> whose lifetime we control.\n")
  rs.add("unsafe impl Send for EventHolderEntry {}\n")
  rs.add("unsafe impl Sync for EventHolderEntry {}\n\n")
  rs.add(
    "static EVENT_HOLDER_REG: OnceLock<Mutex<Vec<EventHolderEntry>>> = OnceLock::new();\n"
  )
  rs.add("fn event_holder_reg() -> &'static Mutex<Vec<EventHolderEntry>> {\n")
  rs.add("    EVENT_HOLDER_REG.get_or_init(|| Mutex::new(Vec::new()))\n")
  rs.add("}\n\n")
  rs.add(
    "fn register_event_holder(ctx: u32, ptr: *mut c_void, dropper: EventHolderDropper) {\n"
  )
  rs.add(
    "    event_holder_reg().lock().unwrap().push(EventHolderEntry { ctx, ptr, dropper });\n"
  )
  rs.add("}\n\n")
  rs.add("fn drop_event_holders_for_ctx(ctx: u32) {\n")
  rs.add("    let mut g = event_holder_reg().lock().unwrap();\n")
  rs.add("    let mut keep: Vec<EventHolderEntry> = Vec::with_capacity(g.len());\n")
  rs.add("    for e in g.drain(..) {\n")
  rs.add("        if e.ctx == ctx { (e.dropper)(e.ptr); } else { keep.push(e); }\n")
  rs.add("    }\n")
  rs.add("    *g = keep;\n")
  rs.add("}\n\n")

  # Result envelope mirroring C++ Result<T> and Python Result[T].
  rs.add("/// Mirror of Nim's `Result[T, string]` envelope.\n")
  rs.add("#[derive(Debug, Clone)]\n")
  rs.add("pub struct Result<T> {\n")
  rs.add("    inner: ::std::result::Result<T, String>,\n")
  rs.add("}\n\n")
  rs.add("impl<T> Result<T> {\n")
  rs.add("    pub fn ok(value: T) -> Self { Self { inner: Ok(value) } }\n")
  rs.add(
    "    pub fn err<S: Into<String>>(msg: S) -> Self { Self { inner: Err(msg.into()) } }\n"
  )
  rs.add("    pub fn is_ok(&self) -> bool { self.inner.is_ok() }\n")
  rs.add("    pub fn is_err(&self) -> bool { self.inner.is_err() }\n")
  rs.add("    pub fn value(&self) -> Option<&T> { self.inner.as_ref().ok() }\n")
  rs.add(
    "    pub fn error(&self) -> Option<&str> { self.inner.as_ref().err().map(|s| s.as_str()) }\n"
  )
  rs.add(
    "    pub fn into_result(self) -> ::std::result::Result<T, String> { self.inner }\n"
  )
  rs.add("}\n\n")

  # ---- Enum / alias typedefs -------------------------------------------
  if gApiRustEnums.len > 0:
    rs.add("// -------- Enums and type aliases --------\n\n")
    for td in gApiRustEnums:
      rs.add(td)
      rs.add("\n\n")

  # ---- FFI structs (#[repr(C)]) ----------------------------------------
  rs.add("// -------- C ABI types (#[repr(C)]) --------\n\n")
  let createCtxResult = className & "CreateContextResult"
  rs.add("#[repr(C)]\n")
  rs.add("#[derive(Debug)]\n")
  rs.add("pub struct " & createCtxResult & " {\n")
  rs.add("    pub ctx: u32,\n")
  rs.add("    pub error_message: *const c_char,\n")
  rs.add("}\n\n")
  for s in gApiRustFfiStructs:
    rs.add(s)
    rs.add("\n\n")

  # ---- Safe high-level structs -----------------------------------------
  rs.add("// -------- Safe Rust types --------\n\n")
  for s in gApiRustStructs:
    rs.add(s)
    rs.add("\n\n")

  # ---- Per-event callback type aliases, dispatcher statics, trampolines.
  if gApiRustEventCbAliases.len > 0:
    rs.add("// -------- Event dispatchers --------\n\n")
    for line in gApiRustEventCbAliases:
      rs.add(line.replace(ApiLibPrefixPlaceholder, apiPrefix))
      rs.add("\n\n")

  # ---- extern "C" block ------------------------------------------------
  rs.add("// -------- extern \"C\" bindings --------\n\n")
  rs.add("extern \"C\" {\n")
  rs.add("    fn " & apiPrefix & "version() -> *const c_char;\n")
  rs.add("    fn " & apiPrefix & "createContext() -> " & createCtxResult & ";\n")
  rs.add(
    "    fn free_" & libName & "_create_context_result(r: *mut " & createCtxResult &
      ");\n"
  )
  rs.add("    fn " & apiPrefix & "shutdown(ctx: u32);\n")
  rs.add("    fn free_" & libName & "_string(s: *mut c_char);\n")
  for fn in gApiRustExternFns:
    rs.add("    " & fn.replace(ApiLibPrefixPlaceholder, apiPrefix) & "\n")
  rs.add("}\n\n")

  # Helper: convert *const c_char -> String safely.
  rs.add("/// Internal helper: copy a C string (possibly null) into a Rust String.\n")
  rs.add("unsafe fn cstr_to_string(p: *const c_char) -> String {\n")
  rs.add(
    "    if p.is_null() { String::new() } else { CStr::from_ptr(p).to_string_lossy().into_owned() }\n"
  )
  rs.add("}\n\n")

  # ---- Wrapper struct --------------------------------------------------
  rs.add(
    "/// Pythonic / C++-equivalent wrapper around the `" & libName & "` library.\n"
  )
  rs.add("pub struct " & className & " {\n")
  rs.add("    ctx: u32,\n")
  rs.add("}\n\n")

  rs.add("impl " & className & " {\n")
  rs.add("    /// Static semver string baked into the shared library.\n")
  rs.add("    pub fn version() -> String {\n")
  rs.add("        unsafe { cstr_to_string(" & apiPrefix & "version()) }\n")
  rs.add("    }\n\n")

  rs.add("    /// Create a new wrapper instance. The library context is\n")
  rs.add("    /// not yet allocated — call `create_context()` before any\n")
  rs.add("    /// request method.\n")
  rs.add("    pub fn new() -> Self {\n")
  rs.add("        Self { ctx: 0 }\n")
  rs.add("    }\n\n")

  rs.add("    /// Allocate the library context. Returns `Result<()>`.\n")
  rs.add("    pub fn create_context(&mut self) -> Result<()> {\n")
  rs.add(
    "        if self.ctx != 0 { return Result::err(\"Context already created\"); }\n"
  )
  rs.add("        unsafe {\n")
  rs.add("            let mut r = " & apiPrefix & "createContext();\n")
  rs.add("            if !r.error_message.is_null() {\n")
  rs.add("                let msg = cstr_to_string(r.error_message);\n")
  rs.add(
    "                free_" & libName & "_create_context_result(&mut r as *mut _);\n"
  )
  rs.add("                return Result::err(msg);\n")
  rs.add("            }\n")
  rs.add("            self.ctx = r.ctx;\n")
  rs.add("            free_" & libName & "_create_context_result(&mut r as *mut _);\n")
  rs.add(
    "            if self.ctx == 0 { return Result::err(\"Library context creation failed\"); }\n"
  )
  rs.add("            Result::ok(())\n")
  rs.add("        }\n")
  rs.add("    }\n\n")

  rs.add("    pub fn valid_context(&self) -> bool { self.ctx != 0 }\n\n")
  rs.add("    pub fn ctx(&self) -> u32 { self.ctx }\n\n")

  rs.add("    /// Tear down the library context. Idempotent.\n")
  rs.add("    pub fn shutdown(&mut self) {\n")
  rs.add("        if self.ctx != 0 {\n")
  rs.add("            unsafe { " & apiPrefix & "shutdown(self.ctx); }\n")
  rs.add("            // Free every event-callback holder boxed for this ctx.\n")
  rs.add("            // Done AFTER shutdown so the C broker has finished\n")
  rs.add("            // dispatching to all listeners before we drop them.\n")
  rs.add("            drop_event_holders_for_ctx(self.ctx);\n")
  rs.add("            self.ctx = 0;\n")
  rs.add("        }\n")
  rs.add("    }\n\n")

  # Request methods.
  for m in gApiRustMethods:
    rs.add(
      m.replace("__LIB_OWNER_CLASS__", className).replace(
        ApiLibPrefixPlaceholder, apiPrefix
      )
    )
    rs.add("\n\n")

  # Event methods.
  for m in gApiRustEventMethods:
    rs.add(
      m.replace("__LIB_OWNER_CLASS__", className).replace(
        ApiLibPrefixPlaceholder, apiPrefix
      )
    )
    rs.add("\n\n")

  rs.add("}\n\n")

  rs.add("impl Default for " & className & " {\n")
  rs.add("    fn default() -> Self { Self::new() }\n")
  rs.add("}\n\n")

  rs.add("impl Drop for " & className & " {\n")
  rs.add("    fn drop(&mut self) { self.shutdown(); }\n")
  rs.add("}\n")

  try:
    writeFile(srcDir & "/lib.rs", rs)
  except IOError:
    error(
      "Failed to write generated Rust source '" & srcDir & "/lib.rs': " &
        getCurrentExceptionMsg()
    )

{.push raises: [].}
{.pop.}
