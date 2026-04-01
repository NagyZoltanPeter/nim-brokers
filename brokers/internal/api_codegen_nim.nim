## api_codegen_nim
## ----------------
## Nim-side C ABI code generation helpers for the FFI API system.
##
## Owns:
## - `toCFieldType` — maps Nim types to their C-compatible Nim equivalents
##   (used in `{.exportc.}` struct definitions)
## - `isCStringType` — checks if a Nim type maps to a C string
##
## These procs are used by `api_type.nim` (for CItem struct generation)
## and by the broker macros (for CResult struct generation).

{.push raises: [].}

import std/[macros, strutils]
import ./api_codegen_c

export api_codegen_c

# ---------------------------------------------------------------------------
# Nim → C-compatible Nim type mapping
# ---------------------------------------------------------------------------

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

{.pop.}
