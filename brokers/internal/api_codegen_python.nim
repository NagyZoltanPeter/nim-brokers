## api_codegen_python
## -------------------
## Python wrapper code generation for the FFI API system.
##
## Owns:
## - Python type mapping procs (Nim → ctypes/Python types)
## - Compile-time accumulators for Python structs, methods, events
## - `generatePythonFile` — writes the `.py` wrapper file
##
## The generated Python module uses ctypes to call the C API, providing
## a Pythonic wrapper class with context management, dataclasses, and
## type-safe method signatures.

{.push raises: [].}

import std/[macros, os, strutils]
import ./api_codegen_c

export api_codegen_c

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
    of "uint8", "byte":
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
      # Check schema registry for enums and distinct/alias types
      if isEnumRegistered($nimType):
        "ctypes.c_int32"
      elif isAliasOrDistinctRegistered($nimType):
        nimTypeToCtypes(ident(resolveUnderlyingType($nimType)))
      else:
        $nimType & "CItem" # user-defined ctypes Structure
  of nnkBracketExpr:
    if isSeqType(nimType):
      "ctypes.c_void_p" # pointer to array
    elif isArrayTypeNode(nimType):
      # Element type — caller appends " * N" for _fields_ entries
      nimTypeToCtypes(ident(arrayNodeElemName(nimType)))
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
        "uint64", "byte":
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
      let elemName = seqItemTypeName(nimType)
      "list[" & nimTypeToPyAnnotation(ident(elemName)) & "]"
    elif isArrayTypeNode(nimType):
      let elemAnnotation = nimTypeToPyAnnotation(ident(arrayNodeElemName(nimType)))
      "list[" & elemAnnotation & "]"
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
        "uint64", "byte":
      "0"
    of "float", "float32", "float64":
      "0.0"
    of "bool":
      "False"
    of "string", "cstring":
      "\"\""
    else:
      if isEnumRegistered($nimType) or isAliasOrDistinctRegistered($nimType):
        "0"
      else:
        "None"
  of nnkBracketExpr:
    if isSeqType(nimType):
      "field(default_factory=list)"
    elif isArrayTypeNode(nimType):
      "field(default_factory=list)"
    else:
      "None"
  else:
    "None"

# ---------------------------------------------------------------------------
# Compile-time accumulators
# ---------------------------------------------------------------------------

var gApiPyTypedefs* {.compileTime.}: seq[string] = @[]
  ## Python IntEnum classes and type aliases (enums, distinct types).
  ## Output before ctypes structs so downstream code can reference them.

var gApiPyCtypesStructs* {.compileTime.}: seq[string] =
  @[] ## ctypes.Structure subclass definitions (CItem + CResult types).

var gApiPyDataclasses* {.compileTime.}: seq[string] =
  @[] ## Python dataclass definitions (high-level result/item types).

var gApiPyMethods* {.compileTime.}: seq[string] =
  @[] ## Python wrapper class method definitions.

var gApiPyEventMethods* {.compileTime.}: seq[string] =
  @[] ## Python wrapper class on/off event method definitions.

var gApiPyInterfaceSummary* {.compileTime.}: seq[string] =
  @[] ## Dense, type-free Python wrapper interface summary lines.

var gApiPyCallbackSetup* {.compileTime.}: seq[string] =
  @[] ## Python CFUNCTYPE definitions and argtypes/restype setup lines.

# ---------------------------------------------------------------------------
# Python file generation
# ---------------------------------------------------------------------------

{.pop.} # temporarily lift raises:[] for compile-time proc using writeFile

proc generatePythonFile*(outDir: string, libName: string) {.compileTime, raises: [].} =
  ## Writes the accumulated Python wrapper file.
  ensureGeneratedOutputDir(outDir)
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
  py.add("import enum\n")
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
  py.add(
    "            if sys.platform == \"win32\" and hasattr(os, \"add_dll_directory\"):\n"
  )
  py.add("                os.add_dll_directory(str(candidate.parent))\n")
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

  # Enum / type alias definitions (IntEnum classes, SensorId = int, etc.)
  if gApiPyTypedefs.len > 0:
    py.add(
      "# ---------------------------------------------------------------------------\n"
    )
    py.add("# Enums and type aliases\n")
    py.add(
      "# ---------------------------------------------------------------------------\n\n"
    )
    for td in gApiPyTypedefs:
      py.add(td)
      py.add("\n\n")

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
{.pop.}
