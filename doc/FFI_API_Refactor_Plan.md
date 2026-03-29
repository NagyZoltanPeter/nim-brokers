# FFI API Modular Refactor Plan

## Goals

1. **Eliminate `ApiType` friction** -- any Nim type defined before a broker macro can be used as an API type (including in `seq[T]`, nested objects, type aliases). No separate registration macro needed.
2. **Separate codegen per language surface** -- each language (C, C++, Python) gets its own codegen module with its own accumulators. Broker macros write to a shared schema; codegen modules read it.
3. **Split C++ into its own `.hpp`** -- `<libname>.h` is pure C, `<libname>.hpp` includes the `.h` and adds the C++ namespace/class/RAII layer.
4. **Prepare for future surfaces** -- CBOR tunnel (Phase 2), Rust/Go codegen (Phase 3) plug into the same schema without touching broker macros.

---

## Current Architecture (what we're changing)

```
api_common.nim          25+ compile-time globals (gApiCpp*, gApiPy*, gApiHeader*, ...)
                        ALL type mapping procs (Nim->C, Nim->C++, Nim->Python)
                        generateHeaderFile(), generatePythonFile()

api_type.nim            ApiType macro -> registers in gApiFfiStructs
                        Directly writes to gApiCppStructs, gApiPyCtypesStructs, etc.

api_request_broker.nim  RequestBroker(API) macro
                        Directly writes to ALL language accumulators (15+ globals)
                        Generates Nim {.exportc.} AST + C header text + C++ text + Python text

api_event_broker.nim    EventBroker(API) macro
                        Same pattern: writes to ALL language accumulators

api_library.nim         registerBrokerLibrary macro
                        Reads all accumulators, calls generateHeaderFile/generatePythonFile
```

**Problem:** Every broker macro knows about every language. Adding a language means editing every macro.

---

## Target Architecture

```
src/
  api_schema.nim              Type registry + schema entries + auto-resolution
  api_type_resolver.nim       Two-phase typed/untyped external type introspection
  api_codegen_nim.nim         Nim-side code generation ({.exportc.}, encode, free procs)
  api_codegen_c.nim           C header generation (.h)
  api_codegen_cpp.nim         C++ wrapper generation (.hpp)
  api_codegen_python.nim      Python wrapper generation (.py)
  api_request_broker.nim      Slimmed: schema + Nim codegen + calls surface modules
  api_event_broker.nim        Slimmed: schema + Nim codegen + calls surface modules
  api_library.nim             Lifecycle + orchestrates all codegen modules
  api_common.nim              Reduced: shared constants, naming helpers only
  api_type.nim                Deprecated shim (forwards to auto-resolution)
```

---

## Phase 1: Type Registry and Auto-Resolution

### Step 1.1: Create `api_schema.nim`

New file. Central compile-time type and API registry.

**Types:**

```nim
type
  ApiFieldDef* = object
    name*: string
    nimType*: string           # "int64", "string", "seq[DeviceInfo]", etc.
    isSeq*: bool
    seqElementType*: string    # populated when isSeq = true
    isObject*: bool            # true when type resolves to an object (nested)

  ApiTypeEntry* = object
    name*: string
    fields*: seq[ApiFieldDef]
    isAlias*: bool             # type MyEvent = DeviceInfo
    aliasTarget*: string       # "DeviceInfo" if isAlias

  ApiRequestEntry* = object
    typeName*: string          # "ListDevices"
    typeDisplayName*: string   # sanitized
    fields*: seq[ApiFieldDef]  # result fields
    zeroArgSig*: bool          # has zero-arg signature
    argSig*: bool              # has arg-based signature
    params*: seq[ApiFieldDef]  # input parameters (if argSig)
    # Export names (filled during Nim codegen, read by C/C++/Python codegen)
    cResultTypeName*: string   # "ListDevicesCResult"
    cExportFuncName*: string   # "mylib_list_devices" (placeholder until lib name known)
    cExportFuncNameWithArgs*: string
    cFreeFuncName*: string     # "mylib_free_list_devices_result"
    hideFromForeignSurface*: bool  # true for InitializeRequest, ShutdownRequest

  ApiEventEntry* = object
    typeName*: string
    typeDisplayName*: string
    fields*: seq[ApiFieldDef]
    typeId*: int               # auto-assigned
    # Export names
    cOnFuncName*: string       # "mylib_onDeviceStatusChanged"
    cOffFuncName*: string
    cCallbackTypeName*: string # "DeviceStatusChangedCCallback"
    handlerProcName*: string
    cleanupProcName*: string
```

**Compile-time accumulators (language-neutral):**

```nim
var gApiTypeRegistry* {.compileTime.}: seq[ApiTypeEntry] = @[]
var gApiRequestRegistry* {.compileTime.}: seq[ApiRequestEntry] = @[]
var gApiEventRegistry* {.compileTime.}: seq[ApiEventEntry] = @[]
var gApiLibraryName* {.compileTime.}: string = ""
var gApiEventTypeCounter* {.compileTime.}: int = 0
```

**Procs:**

```nim
proc isTypeRegistered*(name: string): bool {.compileTime.}
proc lookupType*(name: string): ApiTypeEntry {.compileTime.}
proc registerType*(entry: ApiTypeEntry) {.compileTime.}
proc registerRequest*(entry: ApiRequestEntry) {.compileTime.}
proc registerEvent*(entry: ApiEventEntry) {.compileTime.}
proc nextEventTypeId*(): int {.compileTime.}
```

**Deliverable:** `src/api_schema.nim` with types, accumulators, and registration procs.

**Test:** Static assertions that registry populates correctly from existing tests.

### Step 1.2: Create `api_type_resolver.nim`

New file. Implements the two-phase external type resolution.

**Mechanism (proven in prototype):**

```nim
macro autoRegisterType*(T: typed): untyped =
  ## Phase 2 (typed): receives a resolved type symbol.
  ## Calls getTypeImpl to extract fields.
  ## Recursively emits autoRegisterType calls for nested object/seq[T] fields.
  ## Registers in gApiTypeRegistry via registerType().

proc discoverExternalTypes*(body: NimNode): seq[NimNode] {.compileTime.} =
  ## Phase 1 helper (called from untyped broker macros):
  ## Scans an untyped AST for field types that are not primitives.
  ## Returns ident nodes for each external type found.
  ## Handles: seq[T], plain ident, type alias (type X = Y).

proc emitAutoRegistrations*(externalIdents: seq[NimNode]): NimNode {.compileTime.} =
  ## Generates autoRegisterType(Ident) calls for each discovered external type.
  ## These calls compile as typed macro invocations, triggering Phase 2.
```

**Key behaviors:**
- Depth-first recursive resolution (GeoCoord before Address before DeviceInfo)
- Duplicate detection (skip if already in `gApiTypeRegistry`)
- Works for: `seq[T]`, nested object fields, type aliases (`type X = Y`)
- Constraint: external types must be defined before the macro call site (normal Nim rule)

**Deliverable:** `src/api_type_resolver.nim`.

**Test:** Compile-time test that defines plain Nim types, uses them in a broker macro, and verifies registry contents via `static:` block.

### Step 1.3: Integrate auto-resolution into broker macros

Modify `api_request_broker.nim` and `api_event_broker.nim`.

**In `generateApiRequestBroker`:**

```nim
proc generateApiRequestBroker(body: NimNode): NimNode =
  # ... existing parsing ...

  # NEW: discover and auto-register external types
  let externalIdents = discoverExternalTypes(body)
  result.add(emitAutoRegistrations(externalIdents))

  # ... rest of generation (now reads from gApiTypeRegistry
  #     instead of calling lookupFfiStruct) ...
```

**Replace all `lookupFfiStruct` calls** with `lookupType` from `api_schema.nim`. The `lookupType` proc returns an `ApiTypeEntry` which has the same field info but in a richer format.

**Same change in `generateApiEventBroker`.**

**Also:** Allow `parseSingleTypeDef` to handle the alias case (`type X = Y`) without wrapping in `distinct` when in API mode. The macro detects this is a type alias, resolves Y's fields, and uses them as the event/request payload.

### Step 1.4: Support multiple type definitions in broker body

Modify `parseSingleTypeDef` or add `parseTypeDefs` (plural) variant.

**Before:**
```nim
proc parseSingleTypeDef*(body, macroName, ...): ParsedBrokerType
  # enforces: exactly one type
```

**After:**
```nim
proc parseTypeDefs*(body, macroName, ...): seq[ParsedBrokerType]
  # allows multiple types
  # identifies primary type (the one in signature return type)
  # all others are supporting types -> auto-registered

proc parseSingleTypeDef*(body, macroName, ...): ParsedBrokerType
  # backward compat wrapper: calls parseTypeDefs, asserts len == 1
```

This enables:
```nim
RequestBroker(API):
  type DeviceInfo = object       # supporting type (auto-registered)
    deviceId*: int64
    name*: string

  type ListDevices = object      # primary type (in signature)
    devices*: seq[DeviceInfo]

  proc signature*(): Future[Result[ListDevices, string]] {.async.}
```

### Step 1.5: Deprecate `ApiType`

Keep `api_type.nim` but make it a thin shim:

```nim
macro ApiType*(body: untyped): untyped =
  ## Deprecated: types are now auto-registered when used in broker macros.
  ## This macro remains for backward compatibility.
  {.warning: "ApiType is deprecated. Define types as plain Nim objects " &
    "and reference them directly in RequestBroker(API)/EventBroker(API).".}
  # Still works: parses the type, registers it, generates CItem/encode
  generateApiType(body)
```

**Existing code continues to compile.** The warning nudges toward the new pattern.

### Step 1.6: Migrate examples

Update `examples/ffiapi/nimlib/mylib.nim` to use the new pattern:

**Before:**
```nim
ApiType:
  type DeviceInfo = object
    deviceId*: int64
    name*: string
    deviceType*: string
    address*: string
    online*: bool

ApiType:
  type AddDeviceSpec = object
    name*: string
    deviceType*: string
    address*: string

RequestBroker(API):
  type ListDevices = object
    devices*: seq[DeviceInfo]
  proc signature*(): ...
```

**After:**
```nim
type DeviceInfo* = object
  deviceId*: int64
  name*: string
  deviceType*: string
  address*: string
  online*: bool

type AddDeviceSpec* = object
  name*: string
  deviceType*: string
  address*: string

RequestBroker(API):
  type ListDevices = object
    devices*: seq[DeviceInfo]
  proc signature*(): ...
```

Also update torpedo example.

### Phase 1 Verification

- All existing tests pass (`nimble test`, `nimble testApi`, `nimble testFfiApi`)
- New compile-time tests verify auto-resolution of:
  - `seq[ExternalType]`
  - Nested object fields (`field: ExternalType`)
  - Type aliases (`type MyEvent = ExternalType`)
  - Deep nesting (3+ levels)
  - Cross-broker type sharing (same type in two broker blocks)
- Generated `.h` and `.py` files are identical to pre-refactor output
- `ApiType` still works (with deprecation warning)

---

## Phase 2: Codegen Surface Separation

### Step 2.1: Create `api_codegen_c.nim`

Extract C header generation from `api_common.nim` and the broker macros.

**Own accumulators:**

```nim
var gCHeaderDeclarations* {.compileTime.}: seq[string] = @[]
var gCExportWrappers* {.compileTime.}: seq[ApiCExportWrapper] = @[]
```

**Procs called by broker macros:**

```nim
proc appendCTypeStruct*(entry: ApiTypeEntry) {.compileTime.}
  ## Generates C struct typedef for a supporting type (CItem).
  ## Example output: typedef struct { int64_t deviceId; char* name; } DeviceInfoCItem;

proc appendCRequestResult*(entry: ApiRequestEntry) {.compileTime.}
  ## Generates C result struct + function prototype + free prototype.

proc appendCEventCallback*(entry: ApiEventEntry) {.compileTime.}
  ## Generates C callback typedef + on/off function prototypes.

proc appendCLifecycle*(libName: string) {.compileTime.}
  ## Generates createContext, shutdown, free_string prototypes.
```

**Generation proc (called by `api_library.nim`):**

```nim
proc generateCHeaderFile*(libName, outDir: string) {.compileTime.}
  ## Writes <libName>.h:
  ##   #ifndef LIBNAME_H / #define LIBNAME_H
  ##   #include <stdint.h> / <stdbool.h> / <stddef.h>
  ##   #ifdef __cplusplus / extern "C" { / #endif
  ##   ... all struct typedefs ...
  ##   ... all function prototypes ...
  ##   #ifdef __cplusplus / } / #endif
  ##   #endif
```

**Type mapping procs moved here:**
- `nimTypeToCOutput()`
- `nimTypeToCInput()`
- `nimTypeToCSuffix()`
- `generateCStruct()`

### Step 2.2: Create `api_codegen_cpp.nim`

Extract C++ wrapper generation.

**Own accumulators:**

```nim
var gCppStructs* {.compileTime.}: seq[string] = @[]
var gCppClassMethods* {.compileTime.}: seq[string] = @[]
var gCppInterfaceSummary* {.compileTime.}: seq[string] = @[]
var gCppPreamble* {.compileTime.}: seq[string] = @[]
var gCppPrivateMembers* {.compileTime.}: seq[string] = @[]
var gCppConstructorInitializers* {.compileTime.}: seq[string] = @[]
var gCppShutdownStatements* {.compileTime.}: seq[string] = @[]
var gCppEventSupportGenerated* {.compileTime.}: bool = false
```

**Procs called by broker macros:**

```nim
proc appendCppTypeStruct*(entry: ApiTypeEntry) {.compileTime.}
  ## Generates C++ struct with default ctor + ctor from CItem.

proc appendCppRequestResult*(entry: ApiRequestEntry) {.compileTime.}
  ## Generates C++ result struct + inline method on wrapper class.

proc appendCppEventTraits*(entry: ApiEventEntry) {.compileTime.}
  ## Generates EventTraits struct + EventDispatcher alias +
  ## on/off methods + private members + constructor init + shutdown.

proc appendCppLifecycle*(libName: string) {.compileTime.}
  ## Generates createContext/shutdown/ctx methods.
```

**Generation proc:**

```nim
proc generateCppHeaderFile*(libName, outDir: string) {.compileTime.}
  ## Writes <libName>.hpp:
  ##   #pragma once
  ##   #include "<libName>.h"
  ##   #include <string> / <vector> / <functional> / ...
  ##   namespace <libname> {
  ##   template<typename T> class Result { ... };
  ##   ... structs ...
  ##   } // namespace
  ##   ... EventDispatcher template ...
  ##   ... EventTraits structs ...
  ##   class <LibName> { ... };
```

**Type mapping procs moved here:**
- `nimTypeToCpp()`
- `nimTypeToCppParam()`
- `nimTypeToCppCallbackParam()`

### Step 2.3: Create `api_codegen_python.nim`

Extract Python wrapper generation.

**Own accumulators:**

```nim
var gPyCtypesStructs* {.compileTime.}: seq[string] = @[]
var gPyDataclasses* {.compileTime.}: seq[string] = @[]
var gPyMethods* {.compileTime.}: seq[string] = @[]
var gPyEventMethods* {.compileTime.}: seq[string] = @[]
var gPyInterfaceSummary* {.compileTime.}: seq[string] = @[]
var gPyCallbackSetup* {.compileTime.}: seq[string] = @[]
```

**Procs called by broker macros:**

```nim
proc appendPyTypeStruct*(entry: ApiTypeEntry) {.compileTime.}
  ## Generates ctypes.Structure + @dataclass.

proc appendPyRequestResult*(entry: ApiRequestEntry) {.compileTime.}
  ## Generates ctypes CResult + result dataclass + wrapper method.

proc appendPyEventCallback*(entry: ApiEventEntry) {.compileTime.}
  ## Generates CFUNCTYPE + on/off methods.

proc appendPyLifecycle*(libName: string) {.compileTime.}
  ## Generates context manager, createContext, shutdown.
```

**Generation proc:**

```nim
proc generatePythonFile*(libName, outDir: string) {.compileTime.}
  ## Writes <libName>.py (same structure as current, reads own accumulators).
```

**Type mapping procs moved here:**
- `nimTypeToCtypes()`
- `nimTypeToCtypesArray()`
- `nimTypeToPyAnnotation()`
- `nimTypeToPyDefault()`
- `nimTypeToPythonType()`

### Step 2.4: Create `api_codegen_nim.nim`

Extract Nim-side C ABI code generation (the `{.exportc.}` procs, encode/free procs).

This is the code that currently lives inline in the broker macros as `quote do:` blocks.

**Procs:**

```nim
proc generateNimTypeCodegen*(entry: ApiTypeEntry): NimNode {.compileTime.}
  ## Generates:
  ##   type <TypeName>CItem* {.exportc.} = object
  ##     field1*: cFieldType
  ##   proc encode<TypeName>ToCItem*(item: TypeName): <TypeName>CItem

proc generateNimRequestCodegen*(entry: ApiRequestEntry): NimNode {.compileTime.}
  ## Generates:
  ##   type <TypeName>CResult* {.exportc.} = object
  ##     error_message*: cstring
  ##     ...fields...
  ##   proc encode<TypeName>ToC*(obj: TypeName): <TypeName>CResult
  ##   proc free_<export_name>_result*(r: ptr CResult)
  ##   proc <export_name>*(ctx: uint32, ...): CResult {.exportc, cdecl, dynlib.}

proc generateNimEventCodegen*(entry: ApiEventEntry): NimNode {.compileTime.}
  ## Generates:
  ##   proc handle<TypeName>Registration*(...)
  ##   proc cleanup<TypeName>Listeners*(...)
  ##   proc on<TypeName>*(...) {.exportc, cdecl, dynlib.}
  ##   proc off<TypeName>*(...) {.exportc, cdecl, dynlib.}
```

**Type mapping procs moved here:**
- `toCFieldType()`
- `isCStringType()`
- `isSeqType()`
- `seqItemTypeName()`
- `allocCStringCopy()`
- `allocSharedCString()` / `freeSharedCString()`

### Step 2.5: Slim down `api_common.nim`

After extraction, `api_common.nim` retains only:

```nim
# Shared constants
const ApiLibPrefixPlaceholder* = "APILIBPREFIX_"

# Shared naming helpers
proc apiPublicCName*(suffix: string): string {.compileTime.}
proc toSnakeCase*(s: string): string {.compileTime.}
proc toCamelCase*(s: string): string {.compileTime.}

# isPrimitive check (used by type resolver and all codegen modules)
proc isNimPrimitive*(typeName: string): bool {.compileTime.}
```

Everything else moves to the codegen modules or `api_schema.nim`.

### Step 2.6: Refactor broker macros to use codegen modules

**Before (in `generateApiRequestBroker`):**
```nim
# 800+ lines mixing Nim AST generation, C header strings,
# C++ class method strings, Python ctypes strings
```

**After:**
```nim
proc generateApiRequestBroker(body: NimNode): NimNode =
  result = newStmtList()

  # 1. Parse body, discover external types
  let parsed = parseTypeDefs(body, "RequestBroker", collectFieldInfo = true)
  let externalIdents = discoverExternalTypes(body)
  result.add(emitAutoRegistrations(externalIdents))

  # 2. Build schema entry
  var entry = buildRequestEntry(parsed, signatureNode)

  # 3. Generate MT broker code (unchanged)
  result.add(generateMtRequestBroker(body))

  # 4. Generate Nim C ABI code ({.exportc.} procs)
  let (nimAst, exportNames) = generateNimRequestCodegen(entry)
  result.add(nimAst)
  entry.cResultTypeName = exportNames.resultType
  entry.cExportFuncName = exportNames.funcName
  entry.cFreeFuncName = exportNames.freeFuncName

  # 5. Register in schema
  registerRequest(entry)

  # 6. Append to each language surface
  appendCRequestResult(entry)
  appendCppRequestResult(entry)
  when defined(BrokerFfiApiGenPy):
    appendPyRequestResult(entry)
```

Each step is ~5 lines. The complexity lives in the codegen modules, not the macro.

### Step 2.7: Split `.h` / `.hpp`

Modify `api_library.nim` to call two separate generation procs:

```nim
# In registerBrokerLibrary:
generateCHeaderFile(libName, outDir)      # writes <libName>.h (pure C)
generateCppHeaderFile(libName, outDir)    # writes <libName>.hpp (includes .h)
when defined(BrokerFfiApiGenPy):
  generatePythonFile(libName, outDir)     # writes <libName>.py
```

The `.hpp` file starts with:

```cpp
#pragma once
#include "<libName>.h"    // C declarations

#include <string>
#include <vector>
#include <functional>
// ...

namespace <libname> {
// Result<T> template
// Structs with RAII constructors from CItem/CResult
}

// EventDispatcher template
// EventTraits structs
// Wrapper class
```

Pure C users include only `.h`. C++ users include `.hpp` and get the full RAII experience.

### Step 2.8: Update `api_library.nim`

The lifecycle macro now orchestrates all codegen modules:

```nim
macro registerBrokerLibrary*(body: untyped): untyped =
  # ... existing lifecycle code generation ...

  # Append lifecycle to each surface
  appendCLifecycle(libName)
  appendCppLifecycle(libName)
  when defined(BrokerFfiApiGenPy):
    appendPyLifecycle(libName)

  # Generate all output files
  generateCHeaderFile(libName, outDir)
  generateCppHeaderFile(libName, outDir)
  when defined(BrokerFfiApiGenPy):
    generatePythonFile(libName, outDir)
```

### Phase 2 Verification

- All existing tests pass
- Generated `.h` output matches pre-refactor (byte-for-byte or semantic diff)
- New `.hpp` is the C++ portion extracted from the old `.h`
- Generated `.py` output matches pre-refactor
- C example compiles with `#include "mylib.h"` only
- C++ example compiles with `#include "mylib.hpp"`
- Python example runs unchanged
- Torpedo example builds and runs

---

## Implementation Order and Dependencies

```
Step 1.1: api_schema.nim              (no deps, can start immediately)
Step 1.2: api_type_resolver.nim       (depends on 1.1)
Step 1.3: Integrate into brokers      (depends on 1.1, 1.2)
Step 1.4: Multi-type broker bodies    (depends on 1.3)
Step 1.5: Deprecate ApiType           (depends on 1.3)
Step 1.6: Migrate examples            (depends on 1.3, 1.5)
── Phase 1 complete ──

Step 2.1: api_codegen_c.nim           (depends on Phase 1)
Step 2.2: api_codegen_cpp.nim         (depends on 2.1 for .h/.hpp split)
Step 2.3: api_codegen_python.nim      (independent of 2.1/2.2)
Step 2.4: api_codegen_nim.nim         (depends on 1.1 for schema types)
Step 2.5: Slim api_common.nim         (depends on 2.1-2.4)
Step 2.6: Refactor broker macros      (depends on 2.1-2.5)
Step 2.7: Split .h / .hpp             (depends on 2.1, 2.2)
Step 2.8: Update api_library.nim      (depends on 2.1-2.7)
── Phase 2 complete ──
```

## Estimated LOC per step

| Step | New code | Modified code | Deleted code | Net |
|------|----------|---------------|--------------|-----|
| 1.1  | ~120     | 0             | 0            | +120 |
| 1.2  | ~100     | 0             | 0            | +100 |
| 1.3  | ~40      | ~80           | ~20          | +100 |
| 1.4  | ~50      | ~30           | 0            | +80  |
| 1.5  | ~10      | ~5            | 0            | +15  |
| 1.6  | 0        | ~30           | ~20          | -10  |
| 2.1  | ~200     | 0             | 0            | +200 |
| 2.2  | ~250     | 0             | 0            | +250 |
| 2.3  | ~300     | 0             | 0            | +300 |
| 2.4  | ~250     | 0             | 0            | +250 |
| 2.5  | 0        | ~50           | ~800         | -750 |
| 2.6  | ~100     | ~600          | ~1200        | -500 |
| 2.7  | ~30      | ~20           | 0            | +50  |
| 2.8  | ~20      | ~40           | ~30          | +30  |
| **Total** | **~1470** | **~855** | **~2070** | **+235** |

Net result: ~235 more lines, but spread across 8 focused modules instead of 3 monolithic ones.

---

## File Dependency Graph (after refactor)

```
helper/broker_utils.nim        (unchanged, no API deps)
      |
api_common.nim                 (slimmed: constants + naming helpers)
      |
api_schema.nim                 (type registry + schema entries)
      |
api_type_resolver.nim          (auto-resolution, depends on schema)
      |
      +-- api_codegen_nim.nim   (Nim {.exportc.} generation)
      |
      +-- api_codegen_c.nim     (C header generation)
      |
      +-- api_codegen_cpp.nim   (C++ wrapper generation)
      |
      +-- api_codegen_python.nim (Python wrapper generation)
      |
      +-- [future: api_codegen_cbor.nim]
      +-- [future: api_codegen_rust.nim]
      +-- [future: api_codegen_go.nim]
      |
api_request_broker.nim         (schema + Nim codegen + calls surfaces)
api_event_broker.nim           (schema + Nim codegen + calls surfaces)
      |
api_library.nim                (lifecycle + orchestrates all generation)
      |
api_type.nim                   (deprecated shim)
```

---

## Risk Mitigation

**Risk: Compile-time ordering breaks.**
The two-phase approach (untyped -> typed) relies on Nim expanding macro-emitted code in order. Proven in prototype, but must be tested with the full broker machinery.
*Mitigation:* Step 1.2 includes comprehensive compile-time tests before touching broker macros.

**Risk: Generated output diverges.**
Refactoring codegen into modules could subtly change whitespace, ordering, or naming in generated files.
*Mitigation:* Snapshot current `.h`, `.hpp`, `.py` outputs. Diff against refactored output after each step. Keep a `test_codegen_snapshot` test.

**Risk: Phase 2 is too large to land atomically.**
8 substeps touching ~3000 lines.
*Mitigation:* Steps 2.1-2.4 (new files) can land first as dead code. Step 2.5-2.6 (the actual switchover) is a single focused PR. Step 2.7-2.8 (.h/.hpp split) is a separate PR.

**Risk: `ApiType` removal breaks downstream.**
Projects depending on `ApiType` would break.
*Mitigation:* Keep `ApiType` working (with deprecation warning) for at least one release cycle.

---

## Future Phases (out of scope, but guided by this design)

**Phase 3: CBOR Tunnel Surface**
- New `api_codegen_cbor.nim`
- Adds `appendCborRequest(entry)` / `appendCborEvent(entry)`
- Generates CBOR encode/decode per schema entry
- 3 generic C exports: `invoke`, `subscribe`, `free_buffer`
- Schema manifest file (`<libName>.schema.json`) for external tooling

**Phase 4: Rust / Go Codegen**
- New `api_codegen_rust.nim` -- generates `.rs` file with `#[derive(Deserialize)]` structs + invoke wrappers
- New `api_codegen_go.nim` -- generates `.go` file with CBOR-tagged structs + thin CGo wrapper
- Both consume CBOR tunnel, not C ABI
- Both read from the same `gApiRequestRegistry` / `gApiEventRegistry`
- ~200-300 LOC each (just struct definitions + thin methods)
