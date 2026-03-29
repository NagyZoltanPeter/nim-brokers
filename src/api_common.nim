## API Common
## ----------
## Shared utilities for FFI API broker code generation.
##
## After the Phase 2 codegen surface separation, this module is a thin
## coordination layer that:
## - Re-exports all codegen modules (C, C++, Python, Nim) for backward compat
## - Owns the legacy FFI struct registry bridge
## - Owns compile-time accumulators that are shared across broker macros
##   (event counters, handler entries, cleanup proc names)
## - Provides runtime memory helpers for the FFI boundary
##
## This module is only used when compiling with `-d:BrokerFfiApi`.

{.push raises: [].}

import std/macros

# ---------------------------------------------------------------------------
# Re-export all codegen modules — existing code that imports api_common
# continues to see all type mapping procs, accumulators, and generation procs.
# ---------------------------------------------------------------------------

import ./api_codegen_c
import ./api_codegen_cpp
import ./api_codegen_python
import ./api_codegen_nim
import ./api_schema

export api_codegen_c
export api_codegen_cpp
export api_codegen_python
export api_codegen_nim
export api_schema

# ---------------------------------------------------------------------------
# Library name accumulator
# ---------------------------------------------------------------------------

var gApiLibraryName* {.compileTime.}: string = ""

# ---------------------------------------------------------------------------
# Compile-time accumulators for delivery thread event system
# ---------------------------------------------------------------------------

var gApiEventTypeCounter* {.compileTime.}: int = 0
  ## Auto-incrementing type ID for EventBroker(API) types.
  ## NOTE: Must be incremented directly (not via a helper proc) because the
  ## Nim VM does not persist side effects from called compileTime procs.

var gApiSharedBrokerGenerated* {.compileTime.}: bool = false
  ## Flag: has the shared RegisterEventListenerResult RequestBroker been emitted?

var gApiEventHandlerEntries* {.compileTime.}: seq[(int, string)] =
  @[] ## Accumulates (typeId, handlerProcName) pairs for the aggregate provider.

var gApiEventCleanupProcNames* {.compileTime.}: seq[string] =
  @[] ## Accumulates cleanup proc names for delivery thread teardown.

var gApiRequestCleanupProcNames* {.compileTime.}: seq[string] =
  @[] ## Accumulates cleanup proc names for request provider teardown.

# ---------------------------------------------------------------------------
# Legacy FFI struct registry bridge
# ---------------------------------------------------------------------------

var gApiFfiStructs* {.compileTime.}: seq[(string, seq[(string, string)])] = @[]
  ## Legacy registry. Kept for backward compatibility with existing ApiType usage.
  ## New code should use `gApiTypeRegistry` from `api_schema` instead.

proc registerApiFfiStruct*(
    typeName: string, fields: seq[(string, string)]
) {.compileTime.} =
  ## Register a type in both the legacy and new registries.
  gApiFfiStructs.add((typeName, fields))
  registerFromFieldTuples(typeName, fields)

proc lookupFfiStruct*(typeName: string): seq[(string, string)] {.compileTime.} =
  ## Look up type fields. Checks the new type registry first, then falls back
  ## to the legacy registry for backward compatibility.
  if isTypeRegistered(typeName):
    return lookupTypeFields(typeName)
  for (name, fields) in gApiFfiStructs:
    if name == typeName:
      return fields
  error(
    "Type '" & typeName & "' not registered. " &
      "Define it as a plain Nim type before the broker macro, " &
      "or declare it with `ApiType:` for explicit registration."
  )

{.pop.}

# ---------------------------------------------------------------------------
# Runtime memory helpers
# ---------------------------------------------------------------------------

proc allocCStringCopy*(s: string): cstring =
  ## Allocates a copy of a Nim string as a shared C string.
  ## The caller frees it via the generated FFI free helpers, which may run on
  ## a different thread than the allocation site under --mm:refc.
  if s.len == 0:
    return nil
  let buf = cast[cstring](allocShared(s.len + 1))
  copyMem(buf, unsafeAddr s[0], s.len)
  cast[ptr char](cast[int](buf) + s.len)[] = '\0'
  buf

proc freeCString*(s: cstring) =
  ## Frees a C string previously allocated by allocCStringCopy.
  if not s.isNil:
    deallocShared(s)

# ---------------------------------------------------------------------------
# Shared-memory string helpers for cross-thread event data
# ---------------------------------------------------------------------------

proc allocSharedCString*(s: string): cstring =
  ## Allocate a C string copy in shared memory (safe for cross-thread use).
  allocCStringCopy(s)

proc freeSharedCString*(s: cstring) =
  ## Free a C string allocated by `allocSharedCString`.
  freeCString(s)
