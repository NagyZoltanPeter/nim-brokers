# nim-brokers FFI / wrapper issues — collection

Single place to track nim-brokers bugs found while building the Logos Delivery
FFI library (`logos-delivery` → `make onelogosdelivery`, brokers **v3.1.2**).
Add new findings here before fixing.

Work branch: **`fix/ffi-wrapper-type-mapping`** (uncommitted).

Status: **#1 fixed · #3 fixed+verified · #4 fixed+verified · #2 deferred**

---

## 1. `BrokerFfiApiOutDir` referenced but never declared `{.strdefine.}`  — ✅ FIXED

`brokers/api_library.nim:1580`
```nim
let outDir = detectOutputDir(when defined(BrokerFfiApiOutDir): BrokerFfiApiOutDir else: "")
```
`BrokerFfiApiOutDir` is used as a **value** but there is no
`const BrokerFfiApiOutDir {.strdefine.} = ""` anywhere. So `-d:BrokerFfiApiOutDir:<dir>`
makes `defined(BrokerFfiApiOutDir)` true, then fails with
`Error: undeclared identifier: 'BrokerFfiApiOutDir'`. The output dir can't be
redirected; wrappers always land next to the source (project path).

**Fix:** declare the strdefine const, e.g.
`const BrokerFfiApiOutDir* {.strdefine.} = ""` and use it.

**Workaround in use:** the `onelogosdelivery` nimble task moves the generated
files into `build/onelogosdelivery/` post-build.

---

**Done:** declared `const BrokerFfiApiOutDir* {.strdefine.} = ""` in
`api_library.nim`. (The logos-delivery task still moves files post-build for now;
once this lands + re-pins, `-d:BrokerFfiApiOutDir:<dir>` can replace the move.)

---

## 2. `registerBrokerLibrary` `version:` accepts only a string literal  — ⏸ DEFERRED

`brokers/api_library.nim:85-92` — the `version` branch checks `v.kind == nnkStrLit`
and otherwise errors `version must be a string literal`. A string **const**
(e.g. `git_version`, declared `const git_version* {.strdefine.} = "n/a"` and set
via `-d:git_version="…"`) is an unbound ident at the macro → rejected.

**Fix:** also accept `nnkIdent`/`nnkSym` and resolve the const at macro time:
```nim
of nnkIdent, nnkSym:
  let impl = bindSym(v).getImpl
  if impl.kind == nnkConstDef and impl[^1].kind == nnkStrLit: version = impl[^1].strVal
  else: error("version must resolve to a string const", v)
```

**Deferred — harder than it looks:** `registerBrokerLibrary` is an *untyped*
macro and bakes the version into generated header files via `writeFile` *during
macro execution*, so it needs the literal value at macro time. A `{.strdefine.}`
const arrives as an unbound ident, and an untyped macro can't `bindSym`/`getImpl`
a call-site symbol (the const lives in the caller's scope, not nim-brokers').
The const-resolution sketch below won't work without restructuring how the
header version is emitted (e.g. defer it to generated-code compile time).

**Workaround in use:** hard-coded `version: "0.38.1"` literal.

---

## 3. Type discovery does not resolve *derived* primitive types  — ✅ FIXED + VERIFIED

The nim→FFI mapping only recognises a fixed set of base types; it does **not**
follow **aliases**, **distinct**, generic **typeclasses**, or `Option[T]` to a
mappable underlying type. As a result it emits `// TODO: Nim type 'X' not yet
mappable`, and any request/event whose fields/params/returns use such a type is
**dropped entirely** from every wrapper (`.hpp`, `.py`, `.h`, rust, go).

Observed in `build/onelogosdelivery/logosdelivery.hpp`:

| Nim type | Definition | Should map to | Emitted |
| --- | --- | --- | --- |
| `ContentTopic` | `= string` (alias) | `std::string` / `str` | TODO not mappable |
| `PubsubTopic` | `= string` (alias) | `std::string` | TODO not mappable |
| `ChannelId` | `= SdsChannelID = string` | `std::string` | TODO not mappable |
| `Timestamp` | `= int64` (alias) | `int64_t` | TODO not mappable |
| `RequestId` | `= distinct string` | `std::string` | response types (`Send`, …) "not emittable" |
| `WakuMessageHash` | array/distinct bytes | bytes | TODO not mappable |
| `Option[uint64]` | concretely `Option[uint64]` | optional<uint64_t> | discovered as `Option[CompiledIntTypes]` (typeclass not concretized) → not mappable |
| `Option[Curve25519Key]` | option of bytes | optional<bytes> | not mappable |
| `seq[ContentTopic]` | seq of alias | `vector<string>` | not mappable (cascades from element) |
| `seq[WakuMessageHash]` | seq of bytes-ish | `vector<bytes>` | not mappable |

**Cascade:** because the primitives above aren't resolved, the structs that hold
them have holes (`WakuMessage`, `MessageEnvelope`, `ReceivedMessage`,
`StoreQueryRequest`, channel events…), and **every method** that takes/returns
them is omitted — `send`, `subscribe`, `unsubscribe`, `create_reliable_channel`,
`close_channel`, `send_on_channel`, and the entire Kernel surface
(`relay_publish`, `relay_subscribe`, `store_query`, `build_content_topic`, …).
i.e. the wrappers currently expose **almost no callable API**.

**Root cause (precise):** the per-language mappers already resolve *registered*
aliases (`isTypeRegistered → atkAlias → resolveUnderlyingType`). The gap was
**registration**: `api_type_resolver.nim` used `getTypeInst` to detect aliases,
which only echoes the alias's own name for a simple `type X = string`. A probe
confirmed `getTypeImpl` resolves fully through the chain (`ContentTopic`→`string`,
`ChannelId`→`string`, even alias-of-alias).

**Done (branch `fix/ffi-wrapper-type-mapping`):**
- `autoRegisterApiType` — new branch: if `getTypeImpl(sym).kind == nnkSym` and the
  base differs from the type name, register a `makeAliasEntry(..., atkAlias)`.
- `collectNestedTypeNodes` — register alias-typed fields (direct and `seq[alias]`
  elements) via the `getTypeImpl` base comparison instead of `getTypeInst`.

**Verified:** added a throwaway `type TopicName = string` with `topic: TopicName`
+ `topics: seq[TopicName]` to `test/typemappingtestlib`; the generated
`typemappingtestlib.hpp` now emits `using TopicName = std::string;`,
`std::string topic`, `std::vector<std::string> topics`, **0 "not yet mappable"**.
All four wrappers benefit (shared registry resolution). Test case reverted.

**Still open within this item:** `Option[uint64]` is discovered as
`Option[CompiledIntTypes]` (generic int typeclass not concretized) — separate
fix; affects `paginationLimit` etc.

---

## 4. `seq[byte]` maps to `jsoncons::byte_string`, not `std::vector<uint8_t>`  — ✅ FIXED + VERIFIED (C++ only)

**Done (branch `fix/ffi-wrapper-type-mapping`):** the composable `Bytes`-wrapper
landed in `api_codegen_cbor_hpp.nim`. `seq[byte]` now maps to a per-library
`struct Bytes : std::vector<uint8_t>` (idiomatic, dependency-free) whose
`json_type_traits` force a CBOR byte string (major type 2) on the wire.

**Why it composes (the key mechanism):** specialising
`is_json_type_traits_declared<LIB::Bytes>` is what makes it work. jsoncons'
built-in byte-container paths — the `json_conv_traits` container partial-spec
(`json_conv_traits.hpp:546`, gated `!is_json_conv_traits_declared`, which
*inherits* from `is_json_type_traits_declared`) and the three `encode_traits`
container specs (`encode_traits.hpp:238/266/293`, gated
`!is_json_type_traits_declared`) — would otherwise encode `std::vector<uint8_t>`
as a CBOR **array** (major type 4). Setting the declared flag disables all of
them, so both encode and decode fall through to the custom traits. Because the
traits attach to the *type*, `std::optional<Bytes>`, `std::vector<Bytes>`, and
nested structs (`Inner.bytes`) compose automatically — no per-struct wire mirror
(the dead end documented below).

**Other languages were already correct** — #4 was C++-only:
| Wrapper | Byte encoding | Status |
| --- | --- | --- |
| C++ (jsoncons) | encoded `vector<uint8_t>` as CBOR array | **fixed via `Bytes`** |
| Python (cbor2) | `bytes` → byte string natively | already correct |
| Rust (ciborium) | `#[serde(with="serde_bytes")]` already emitted | already correct |
| Go (fxamacker/cbor) | `[]byte` → byte string by default | already correct |

**Verified:** `test/typemappingtestlib` exercises `seq[byte]` as result
(`ByteSeqRequest`), input param (`BytesEchoRequest`), `Option[seq[byte]]`
(`OptSeqRequest`), and `seq[Inner]` with an inner `seq[byte]` field
(`ListInnersRequest`/`BulkInnersRequest`/`InnersUpdatedEvent`). All four wrapper
round-trip suites pass: **C++ 133/133 under both `--mm:orc` and `--mm:refc`**,
Python 86/86, Rust 133/133, Go 133/133. The hand-written C++ test now constructs
`Bytes payload{...}` (was `jsoncons::byte_string`); the result-side accessors
(`.size()`, `[]`) were already vector-compatible and needed no change.

---

### Original analysis (kept for context)

## 4-orig. `seq[byte]` maps to `jsoncons::byte_string`, not `std::vector<uint8_t>`

`logosdelivery.hpp` emits binary fields (`payload`, `meta`, `proof`) as
`jsoncons::byte_string{}`. That ties the public struct to a **jsoncons-specific
CBOR type** instead of the idiomatic, dependency-free byte vector
(`std::vector<uint8_t>` in C++, `bytes` in Python, `Vec<u8>` in Rust, `[]byte` in
Go).

**Note — it's deliberate, not a typo** (`api_codegen_cbor_hpp.nim:103-111`):
`std::vector<uint8_t>` would ride the wire as a CBOR **array** (major type 4),
but Nim `cbor_serialization` decodes `seq[byte]` from a CBOR **byte string**
(major type 2). `jsoncons::byte_string` satisfies `is_basic_byte_string` so it
encodes as major type 2 — required for correctness, at the cost of an
unergonomic public type.

**Design (refined after a spike):**

- ❌ **Per-struct wire-mirror does NOT compose.** I prototyped the Table-key
  pattern for direct `seq[byte]` fields (public `std::vector<uint8_t>`, wire
  `jsoncons::byte_string`, field-by-field conversion in the struct's custom
  traits). It works for a *direct* `seq[byte]` field, but the conversion is
  per-field and keyed on the exact type string `"seq[byte]"`, so it misses
  `Option[seq[byte]]` (→ `std::optional<std::vector<uint8_t>>`) and
  `seq[seq[byte]]` — those then ride the wire as CBOR arrays and break. The
  test lib already has `Option[seq[byte]]`, so this approach *regresses* it.
  (Prototype reverted; mapping is back to `byte_string`.)

- ✅ **Composable fix: a `Bytes` wrapper type.** Emit one type per library that
  derives the idiomatic vector but carries byte-string wire traits:
  ```cpp
  struct Bytes : std::vector<uint8_t> { using std::vector<uint8_t>::vector; };
  namespace jsoncons {
  template <typename Json> struct json_type_traits<Json, LIB::Bytes> {
    using allocator_type = typename Json::allocator_type;
    static bool is(const Json& j) noexcept { return j.is_byte_string(); }
    static LIB::Bytes as(const Json& j) {
      auto bs = j.template as_byte_string<jsoncons::byte_string>();
      return LIB::Bytes(bs.data(), bs.data() + bs.size());
    }
    static Json to_json(const LIB::Bytes& v, const allocator_type& a = {}) {
      return Json(jsoncons::byte_string_arg,
                  jsoncons::span<const uint8_t>(v.data(), v.size()),
                  jsoncons::semantic_tag::none, a);
    }
  };
  }
  ```
  Then map `seq[byte] → LIB::Bytes` in `nimTypeToCppType`. Because the traits
  attach to the *type*, `Option<Bytes>`, `std::vector<Bytes>`, nested structs,
  etc. all compose automatically — no per-struct wire mirror.
  Verified-available jsoncons API: `byte_string`'s `(const uint8_t*, size_t)`
  ctor + `data()/size()`; `Json::is_byte_string()` / `as_byte_string<T>()` /
  `Json(byte_string_arg, span, semantic_tag, alloc)`.

- Replicate the equivalent wrapper per target: Python `bytes` (cbor2 already
  encodes it as a byte string), Rust `serde_bytes`/`Vec<u8>` with a byte-string
  serde adapter, Go `[]byte` (fxamacker/cbor encodes `[]byte` as a byte string
  by default — likely already correct; verify).

Needs a focused session: implement `Bytes`, verify compile + round-trip against
`test/typemappingtestlib` (it already exercises `seq[byte]` and
`Option[seq[byte]]`), then do the other three languages.
