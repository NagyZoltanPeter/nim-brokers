# FFI schema handshake — plan

Branch: `feat-ffi-schema-handshake`

**Status: implemented.** D1–D3 adopted as proposed. Deviations from the plan
below:

- `examples/ffiapi/example/main.c` is **not** touched. It is compiled out
  (`if(FALSE)` in `examples/ffiapi/CMakeLists.txt`) and still targets the
  retired native API. The pure-C usage lives in `doc/FFI_API.md` § "Schema
  verification" instead.
- The env helpers (`brokerSkipSchemaCheck`) are **templates**, and the export
  is wrapped in `push stackTrace/lineTrace/checks: off`. That way the emitted C
  is only `memcpy` + compare + `getenv`: no frame push (`framePtr` threadvar),
  no goto-exception error-flag check, and no unreachable index/overflow raise
  paths.
- No ASAN nimble task was added. The ASAN + UBSan run of
  `test_api_verify_schema` was done ad hoc with the `testSan` flags (refc + ORC
  clean).

## Goal

**Detect**, not prevent, a mismatch between a generated wrapper and the loaded
runtime on the **wire schema**. The check is whole-library for now, and it
must not trip on rebuilds that leave the ABI alone.

This is a diagnostic tool and we trust our users. The library exposes a
verification call. Generated wrappers (C++, Python, Rust, Go) call it
automatically and surface a mismatch as an error. The library never refuses
other calls: `_createContext` and friends are untouched, and a hand-written C
consumer that never calls `_verifySchema` keeps working exactly as today.

| Must report a mismatch | Must NOT report a mismatch |
|---|---|
| A request, event or signal is added, removed or renamed (`apiName`) | Doc-comment edits |
| Arg, field or response type changes (incl. `T` ↔ `Option[T]`, seq/array/Table shape, array size) | Provider or listener body changes, internal refactors |
| An object field is added, removed or renamed | Object field reordering (the wire is a CBOR map keyed by name) |
| An enum value's ordinal or name changes, or a value is added or removed | `version:` string changes (incl. a `git_version` const that changes per commit) |
| Table key type changes | Capacity, timeout and ring knobs (`asyncTimeoutMs`, `asyncQueueDepth`, `requestTimeoutMs`, presets) |
| Codec-convention change in nim-brokers (the wire version bump, see §2) | Nim compiler or brokers version bumps with no codec change |
| Interface (`BrokerInterface(API)`) membership or `returnsInterface` changes | Generated adapter or proc identifiers, `mainClass` name |

The **wrapper supplies** its burned-in fingerprint to `<lib>_verifySchema`. The
**library cross-checks** it against its own compiled-in fingerprint. Opt-out is
an environment variable, read by the library.

## 1. Current state (evidence)

- The only identity is `<lib>_version()` (`brokers/api_library.nim:837-856`).
  Wrappers forward to it (`api_codegen_cbor_hpp.nim:1937`, `_py.nim:857`,
  `_rust.nim:865`, `_go.nim:561`). Nothing is burned into a wrapper and nothing
  is compared.
- CDDL is generated at compile time and embedded in the descriptor
  (`api_library.nim:2434-2451`). It is not a usable hash input as-is: it
  contains doc `;` lines and the generator banner.
- All wrappers and the lib come from one `registerBrokerLibrary` expansion
  (`api_library.nim:2405-2436`). That makes a single compile-time value
  available to every generator.
- Codec facts that decide what is ABI (`api_cbor_codec.nim:41-53`, `:55`):
  - Objects are maps keyed by field name, so field order is not ABI.
  - `requireAllFields = true`, so adding a non-Option field is breaking.
  - `allowUnknownFields = true`.
  - Enums travel as ordinals.
- The status code space lives in `api_common.nim:74-85`. The last code is
  `ApiStatusOneWay = -13`.

## 2. Fingerprint

### 2.1 Format: fixed length

- **32 lowercase hex chars (128 bits).** Exported as a NUL-terminated string,
  but the comparison reads exactly 32 bytes (`<LIB>_SCHEMA_HASH_LEN`). The
  contract is "a pointer to ≥ 32 readable bytes".
- Lib side: `const g<lib>SchemaHash: array[32, char]`. The compare is a
  fixed-length loop or `equalMem` on 32 bytes: no strlen, no allocation on the
  match path.

### 2.2 Algorithm: FNV-1a-128

- **FNV-1a-128**, implemented with two `uint64` limbs (offset basis and prime
  from the FNV spec). About 30 lines of pure Nim, compile-time-VM-safe, no new
  dependency. `std/hashes` is not stable across Nim versions, and the
  `checksums` package and nimcrypto are not deps today.
- This is not a security property. The threat is accidental mismatch. 128 bits
  makes an accidental collision a non-issue.
- The code lives in a new `brokers/internal/api_schema_hash.nim`
  (compile-time only).

### 2.3 Canonical input (ABI only)

Build one canonical text from the compile-time registries, not from the CDDL:

```
brokers-wire:<BrokerFfiWireVersion>
lib:<libName>
req:<apiName>(<argName>:<T>,… sorted by argName)-><RespT>[@iface:<I>]   (sorted by apiName)
evt:<apiName>:<PayloadT>                                                (sorted)
sig:<apiName>:<PayloadT>                                                (sorted)
iface:<name>{req:[…sorted],evt:[…sorted],sig:[…sorted]}                 (sorted)
type:<name>=obj{<field>:<T>,… sorted by field}                          (sorted by name)
type:<name>=enum{<ordinal>:<valueName>,… sorted by ordinal}
```

- **Sources:**
  - `gApiCborRequestEntries` (`apiName`, `argFields`, `responseTypeName`,
    `returnsInterface`)
  - `gApiCborEventEntries`
  - `gApiCborSignalEntries`
  - `gApiInterfaces` (`broker_utils.nim:1148`; needs a read accessor)
  - `gApiTypeRegistry` (`api_schema.nim:42-54`)
- **Type normalisation in `<T>`:**
  - `atkAlias` and `atkDistinct` resolve to their underlying type. They are
    wire-transparent, so they get no `type:` line.
  - Containers are spelled structurally: `seq[T]`, `array[N,T]`,
    `Table[K,V]`, `Option[T]` (`Opt[T]` maps to `Option[T]`, since it is the
    same wire form).
  - Whitespace is stripped.
- **Excluded:** every `doc` field, `version`, `adapterProc`, `mainClass`, all
  capacity and timeout knobs.
- **`BrokerFfiWireVersion`** is a new `int` const in `api_common.nim`. Bump it
  by hand whenever a codec convention changes: enum-as-ordinal, Option
  omission, text map keys, response envelope shape, status codes, call
  framing. This is the only way a nim-brokers change (as opposed to a schema
  change) makes the hashes differ.

### 2.4 Decisions open for review

| # | Question | Proposal |
|---|---|---|
| D1 | Should a type **rename** (same structure) report a mismatch? | **Yes (nominal).** Simpler, and there is no recursion problem. A renamed type also renames the generated wrapper class, so consumer code changes anyway. Structural hashing (inlining referenced types, excluding names) would be more precise but needs cycle handling. |
| D2 | Should an enum value **name** change (same ordinal) report a mismatch? | **Yes.** It is not a wire change, but it is a semantic change: the wrapper would label ordinal 1 differently from the lib. |
| D3 | Opt-out variable: one generic or per-lib? | Generic **`BROKERS_FFI_SKIP_SCHEMA_CHECK=1`**, plus per-lib **`<LIBNAME_UPPER>_SKIP_SCHEMA_CHECK=1`**, because one process can load two broker libs. Either one skips. |

## 3. ABI changes (additive only)

| Symbol | Change |
|---|---|
| `<lib>_verifySchema(const char wrapperHash[32], char libHashOut[33]) -> int32_t` | **New** (13th function). Fixed-size buffers only, no allocation. See §3.1. |
| `ApiStatusSchemaMismatch = -14` | **New** code in `api_common.nim`. Wrappers interpolate the value, same as the other codes. |
| `ApiStatusSchemaSkipped = 1` | **New** positive code. A mismatch happened, but the opt-out env is set. Wrappers treat it as success. |
| Header macros | `#define <LIB>_SCHEMA_HASH "<32 hex>"`, `#define <LIB>_SCHEMA_HASH_LEN 32` |
| Descriptor (`_getSchema`, `_listApis`) | New `schemaHash` field on `LibraryDescriptor` and `ApiList` (`api_cbor_descriptor.nim`) |
| CDDL | Banner comment `; schema-hash: <hex>`. It is informational only, and since the hash is computed from the canonical text, the comment can't feed back into it. |
| `_createContext` and all other existing functions | **Unchanged.** |

The ABI grows from 12 to **13 functions**. Existing compiled consumers keep
working. An old lib loaded by a new wrapper fails symbol resolution for
`_verifySchema`, which counts as detected too. There is no separate
`_schemaHash()` export. The library hash reaches callers through `libHashOut`
and through the descriptor's `schemaHash` field.

### 3.1 `<lib>_verifySchema` semantics: allocation-free

```c
int32_t <lib>_verifySchema(const char wrapperHash[32],  /* may be NULL */
                           char       libHashOut[33]); /* may be NULL; 32 hex + NUL */
```

The array parameter syntax is documentation only: in C and C++ it decays to a
pointer, so the ABI is identical to `const char*` / `char*`. C99
`[static N]` is **not** used. C++ rejects it (the `.h` is included by the
`.hpp`), and it would make the allowed NULL undefined behaviour. The Nim side
declares `ptr array[32, char]` / `ptr array[33, char]`. Nim emits
`NIM_CHAR (*)[N]` internally, which is still a pointer at the ABI level. The
Nim module never includes the generated header, so there is no prototype
clash. Rust: `*const [c_char; 32]` / `*mut [c_char; 33]`. Go: pointer to the
first element. Python: argtypes `c_char * 32` / `c_char * 33`.

| Situation | Return | `libHashOut` (if non-NULL) |
|---|---|---|
| First 32 bytes equal | `0` (`ApiStatusOk`) | lib hash + NUL |
| Mismatch, opt-out env set | `1` (`ApiStatusSchemaSkipped`) | lib hash + NUL |
| Mismatch, no opt-out | `-14` (`ApiStatusSchemaMismatch`) | lib hash + NUL |
| `wrapperHash == NULL` | `-1` (function-local argument error) | lib hash + NUL |

`libHashOut` is filled on every path. Callers pass NULL there to just get the
code, or pass NULL as `wrapperHash` to read the lib hash alone.

**The wrapper formats the message** from data it already holds: its own hash,
`libHashOut` and `<lib>_version()`. The library builds no string.

**Implementation constraints**, so that the proc touches no Nim runtime state
at all:

| Need | Implementation | Avoids |
|---|---|---|
| Lib hash | `const g<lib>SchemaHash: array[33, char]` (32 hex + NUL, in rodata) | Any string object |
| Compare | 32-iteration loop over `wrapperHash[]` (`ptr array[32, char]`) | `$`, `cstring` → `string` conversion |
| Output | `copyMem(libHashOut, addr g<lib>SchemaHash[0], 33)` | Allocation |
| Env, POSIX | `proc c_getenv(n: cstring): cstring {.importc: "getenv", header: "<stdlib.h>".}`: borrowed pointer, test `!= nil and [0] == '1'` | Nim `getEnv` (which returns a heap `string`) |
| Env, Windows | `GetEnvironmentVariableA(name, buf, 2)` into a `array[2, char]` stack buffer | Nim `getEnv`. Also the CRT `getenv`, which reads a startup copy of the env and misses `SetEnvironmentVariableW` from Go and Rust. |
| Logging | None. A skipped mismatch is reported through return code `1`. | chronicles (allocates, uses threadvars) |
| Pragmas | `{.exportc, cdecl, dynlib, raises: [], gcsafe.}`, no `try`, no threadvars | Exception machinery |

Properties:

- Safe with no context, before `_initialize`, and from any foreign thread:
  it does no GC'd allocation, needs no stack registration, and touches no
  threadvar.
- It never reads past 32 bytes of `wrapperHash` and never writes past 33 bytes
  of `libHashOut`.
- The env var is read on every call. That is cheap, and lets tests toggle it.
- It is stateless: it has no effect on any other call.

### 3.2 Memory-model and platform matrix

| Aspect | refc | ORC | Reason |
|---|---|---|---|
| Reading `wrapperHash` | ✅ | ✅ | Borrowed foreign pointer, read-only, 32 bytes, never retained. |
| Writing `libHashOut` | ✅ | ✅ | Caller-owned buffer (stack or static on the wrapper side), 33 bytes copied from rodata. Ownership never transfers. |
| Calling before `_initialize` / from an unregistered foreign thread | ✅ | ✅ | No Nim heap, no GC, no threadvar, no exceptions. Under refc nothing needs the thread's GC stack to be set up. Under ORC there are no RC ops. |

| Platform | Env opt-out read | Note |
|---|---|---|
| Linux / macOS | libc `getenv` (borrowed pointer) | Host-side `os.environ` (Python), `os.Setenv` (Go), `set_var` (Rust) all go through `setenv`. POSIX `getenv` racing `setenv` is UB, so docs say to set it before loading the wrapper. |
| Windows | `GetEnvironmentVariableA` (OS env block) | Sees Python `_wputenv`, Go and Rust `SetEnvironmentVariableW`. The CRT `getenv` would not, because it uses a startup copy. |

## 4. Wrapper changes: automatic check

**Rule 1: each wrapper burns its own literal.** It must not reference the `.h`
macro. Otherwise, swapping the `.so` + `.h` without regenerating the
`.hpp` / `.py` / `.go` would make the macro match the lib and the check would
pass falsely. Only pure-C consumers use the `.h` macro, because for them the
`.h` *is* the wrapper.

**Rule 2: check once, right before `_createContext`**, inside the existing
create path, so the failure arrives through that path's existing error
channel. The cost is one 32-byte compare per created context.

| Wrapper | Burned constant | Where the check runs | Failure surface |
|---|---|---|---|
| C (`api_codegen_cbor_h.nim`) | `#define <LIB>_SCHEMA_HASH` | The consumer calls `<lib>_verifySchema(<LIB>_SCHEMA_HASH, buf)` with `char buf[<LIB>_SCHEMA_HASH_LEN + 1]` if it wants to (optional) | Return code + `buf` |
| C++ (`api_codegen_cbor_hpp.nim:1940`) | `static constexpr char kSchemaHash[] = "…";` in the class | `createContext()` before `<p>createContext(&err)` | Existing `Result<void>` error |
| Python (`api_codegen_cbor_py.nim:907`) | `SCHEMA_HASH = b"…"` module const | Before `_LIB.<p>createContext(...)` | Existing raise path |
| Rust (`api_codegen_cbor_rust.nim:885`) | `pub const SCHEMA_HASH: &[u8; 33] = b"…\0";` | `create_context()` before the extern call | Existing `Err(String)` |
| Go (`api_codegen_cbor_go.nim:576` + native file) | Static C string in the cgo preamble of the **generated .go** (no `C.CString` allocation) | Before `C.<p>createContext(&errPtr)` | Existing `error` |

Each wrapper calls with a stack (C++/Rust/Go) or `ctypes.create_string_buffer(33)`
(Python) `libHashOut`. On `-14` it builds the error from its own values:
`"schema mismatch: <lib> <version()> has <libHashOut>, wrapper has <SCHEMA_HASH>"`.
It treats `0` and `1` as success and doesn't warn on `1`, because the user
set the opt-out deliberately. Every wrapper also re-exports `schemaHash()`
(its own value) as a static / class-level member, like `version()`.

**Native-mode Go/Rust files:** check during Phase 3 whether they still emit a
`createContext` call. If they do, they get the same check.

## 5. Phases

Run `gitnexus_impact` (upstream) before editing each of:
`registerBrokerLibrary`, `generateCborCHeaderFile`,
`generateCborCppHeaderFile`, `generateCborPyFile`, `generateCborRustFile`,
`generateCborGoFile`, `generateCborCddlFile`, `LibraryDescriptor`, `ApiList`.

1. **Canonicaliser + hash** (`api_schema_hash.nim`, `BrokerFfiWireVersion`).
   Verify with a compile-time unit test `test/test_api_schema_hash.nim` that
   builds synthetic registries and asserts:
   - Doc edit, field reorder, version change and knob change → **same** hash.
   - Field type, `Option` wrap, enum ordinal, enum name, apiName, added
     request, wire-version bump → **different** hash.
   - Output is exactly 32 lowercase hex chars.
2. **Library side.** Add:
   - The `_verifySchema` export, following the §3.1 constraints.
   - `ApiStatusSchemaMismatch` and `ApiStatusSchemaSkipped`.
   - The descriptor field, header macros and CDDL banner.

   Verify with a new test (in `test/test_api_library_init.nim` or a sibling)
   covering:
   - Correct hash → 0, and `libHashOut` filled.
   - Wrong hash → -14.
   - NULL `wrapperHash` → -1, with `libHashOut` still filled.
   - NULL `libHashOut` → no write.
   - Generic and per-lib env → 1 (`putEnv` / `delEnv`).
   - Called before `_initialize` → correct result.

   Run `nimble testApi`.
3. **Wrappers.** Make the C++, Py, Rust and Go wrappers call it automatically,
   and add an optional `_verifySchema` call to `examples/ffiapi/example/main.c`
   as the C usage demo. Verify with all `runFfiExample*` and
   `runTorpedoExample*` tasks.
4. **Parity tests.** For each of `test_typemappingtestlib.{cpp,py}`,
   `rust_test` and `go_test`:
   - Assert wrapper `schemaHash()` equals the `libHashOut` returned by a raw
     `_verifySchema` call.
   - Call raw `_verifySchema` with a corrupted hash and expect -14.
   - Set the opt-out env and expect 1, with the wrapper's create path still
     succeeding.

   Verify with `runTypeMapTestLib{Cpp,Py,Rust,Go}` (both MMs).
5. **Drift guard.** Add a golden hash for `typemappingtestlib` in a test
   constant. It fails if canonicalisation changes by accident (e.g. a Nim
   upgrade changes a type spelling). Updating it is a deliberate act that goes
   with a `BrokerFfiWireVersion` review.
6. **Docs.** Update `doc/FFI_API.md` with a new "Schema verification"
   section: format, what counts as a mismatch, the automatic wrapper check,
   env opt-out, optional C usage. In `AGENTS.md`, change "12-function ABI" to
   13, add `ApiStatusSchemaMismatch` / `ApiStatusSchemaSkipped` and the env
   vars. Update `README.md` if
   it lists the ABI. Do not touch CHANGELOG.

## 6. Gates (all must pass before claiming done)

`nimble test`, `nimble testApi`, `nimble runFfiExample{Cpp,Py,Rust,Go}`,
`nimble runTorpedoExample{Cpp,Py,Rust,Go}`,
`nimble runTypeMapTestLib{Cpp,Py,Rust,Go}` (ORC + refc), `nimble nphall`.
Also run one ASAN refc build of the new verify test. Its purpose is to
confirm the buffer bounds (32 bytes read, 33 bytes written) and that the call
works before `_initialize`.

## 7. Out of scope

- **Enforcement.** Neither `_createContext` nor any other call refuses an
  unverified or mismatched caller. If wanted later: `_verifySchema` sets a
  process-global atomic flag and `_createContext` refuses while it is unset.
  Deliberately not done: we detect, we don't prevent.
- Per-API or additive-compatible matching (whole-lib strict only).
- Signing or tamper resistance.
- IPC lane (`registerIpcHost`) handshake. It can reuse the same fingerprint
  later.
