# Associative-Container Support for the Broker FFI/API Type Mapping

Branch: `api-support-associative-containers`
Status: **research / decision doc — not yet implemented**
Goal: extend the baseline / mt / API broker type-mapping lineage so that Nim
`Table[K, V]` (and siblings) round-trip across the FFI surface to
`std::unordered_map`, `dict`, `HashMap`, `map[K]V`.

---

## 0. TL;DR for the decision

- **Baseline + MT brokers** already accept `Table[K,V]` fields today — they
  never serialize, they pass live Nim values. No work needed there beyond a
  test. The whole effort is the **API/FFI (CBOR) lineage**.
- **CBOR needs no envelope.** A `Table`/`OrderedTable` serializes as a native
  CBOR **map (major type 5)**. The codec library (`cbor_serialization`) already
  ships `std/tables.nim` with `read`/`write` bindings.
- **The catch that decides scope:** that library stringifies every key
  (`writer.writeField $key, val`) and its reader only knows how to turn a key
  back into `int`, `float`, or `string`. So **out of the box: keys ∈
  {intN, uintN, float, string}; nothing else.** Enum/bool/distinct/object keys
  need a patch to `nim-cbor-serialization` (we have a local checkout) or are
  declared unsupported.
- **Wire-key asymmetry is the main interop risk.** Even an `int` key goes on
  the wire as a *text* string ("5"), not a CBOR integer key. Every foreign
  wrapper that maps to `map<int, V>` must therefore parse text keys back to
  int. Decide this policy up front (§4).

---

## 1. Current code shape (verified against master, not AGENTS.md)

> ⚠ AGENTS.md still lists `api_codegen_{c,cpp,python,rust,go}.nim` and
> `api_ffi_mode.nim`. Those files are **gone** on master — `brokers/internal/`
> is now CBOR-only (`api_codegen_cbor_{h,hpp,py,rust,go,cddl}.nim`). There is no
> live "native struct-passing" FFI mode to support; the C ABI is fixed-shape
> opaque CBOR bytes. This shrinks scope: **no C-ABI struct layout for maps is
> ever needed** — maps exist only inside the typed wrapper layer.

`seq[T]` is the exact model to copy. Container handling is **special-cased, not
abstracted** — each layer has a parallel `seq[`/`array[` branch:

| Layer | File | seq branch (insert table branch beside it) |
|-------|------|--------------------------------------------|
| Compile-time field model | `brokers/internal/api_schema.nim` | `ApiFieldDef` (`isSeq`, `seqElementType`); `makeFieldDef` parses `"seq[...]"` |
| Nested-type discovery | `brokers/internal/api_type_resolver.nim` | `scanTypeNode`, `collectNestedTypeNodes` register object element types |
| CBOR codec | `brokers/internal/api_cbor_codec.nim` | imports `cbor_serialization/std/options` — **must add `std/tables`** |
| C++ | `brokers/internal/api_codegen_cbor_hpp.nim` | `nimTypeToCppType` |
| Python | `brokers/internal/api_codegen_cbor_py.nim` | `nimTypeToPyHint` |
| Rust | `brokers/internal/api_codegen_cbor_rust.nim` | `nimTypeToRustHint` |
| Go | `brokers/internal/api_codegen_cbor_go.nim` | `nimTypeToGoCborHint` |
| CDDL | `brokers/internal/api_codegen_cbor_cddl.nim` | `nimTypeToCddl` |
| Discovery descriptor | `brokers/internal/api_cbor_descriptor.nim` | runtime field descriptor |

Each `nimType...` mapper is a `startsWith("seq[") → unwrap → recurse → wrap`
shape. A second container kind slots in cleanly; the only new primitive needed
is a **two-parameter unwrap** (`Table[K, V]` → `(K, V)`) vs the existing
single-parameter `unwrapBracket`.

---

## 2. Type-mapping comparison table

`V` = recursively-mapped value type (any type `seq[V]` already supports:
primitive, string, object, nested seq, even nested `Table`). `K` = key type.

| Nim source | C++ (`.hpp`, jsoncons) | Python (cbor2) | Rust (ciborium+serde) | Go (fxamacker) | CDDL | CBOR wire |
|------------|------------------------|----------------|-----------------------|----------------|------|-----------|
| `Table[string, V]` | `std::unordered_map<std::string, Vcpp>` | `Dict[str, Vpy]` | `HashMap<String, Vrs>` | `map[string]Vgo` | `{ * tstr => V }` | map (mt5), text keys |
| `Table[intN, V]` | `std::unordered_map<int64_t, Vcpp>` ⚠ | `Dict[int, Vpy]` ⚠ | `HashMap<i64, Vrs>` ⚠ | `map[int64]Vgo` ⚠ | `{ * int => V }` | map (mt5), **text keys** ⚠ |
| `Table[uintN, V]` | `unordered_map<uint64_t, …>` ⚠ | `Dict[int, …]` ⚠ | `HashMap<u64, …>` ⚠ | `map[uint64]…` ⚠ | `{ * uint => V }` | map, text keys ⚠ |
| `Table[float, V]` | `unordered_map<double, …>` ⚠✗ | `Dict[float, …]` ⚠ | `HashMap<OrderedFloat, …>` ✗ | `map[float64]…` ⚠ | `{ * float => V }` | map, text keys ⚠ |
| `OrderedTable[K, V]` | same as `Table` (✗ order lost) | `dict` (✓ order kept) | `IndexMap`/`BTreeMap` (✗/sorted) | `map` (✗ order lost) | same | map |
| `Table[bool/enum/distinct, V]` | — | — | — | — | — | **unsupported by codec lib** ✗ |
| `Table[Object, V]` | — | — | — | — | — | impossible (non-hashable / not stringifiable) ✗ |
| `HashSet[T]` (stretch) | `std::unordered_set<Tcpp>` | `Set[T]` | `HashSet<Trs>` | `map[T]struct{}` | `[ * T ]` | array/map (see `std/sets.nim`) |

Legend: ✓ ok · ⚠ works but needs key-string conversion on one or both sides ·
✗ semantic loss or unsupported.

### Key-type support — definitive (this is the question that matters)

The binding constraint is `cbor_serialization/std/tables.nim`. **Write** does
`writer.writeField $key, val` (every key stringified via `$`). **Read** does
`value[to(key, KeyType)] = val`, and `to(string, T)` has *exactly three*
overloads — `int`, `float`, `string` — plus a catch-all that is a hard
`{.error: "doesnt support keys with type ...".}`. `KeyType` is the exact field
type, so `int32`/`int64`/`uint*` do **not** match `type int` and hit the error.

| Key type | Status | Why |
|----------|--------|-----|
| `string` | ✅ supported now | identity round-trip |
| `int` (platform-width only) | ✅ supported now | `parseInt` reverse exists. ⚠ width is platform-dependent — risky across FFI |
| `float` / `float64` | ⚠ works in lib, **recommend reject** | `parseFloat` exists, but Rust `HashMap` can't key on `f64` (no `Eq`/`Hash`); text round-trip is precision-fragile |
| `int8/16/32/64`, `uint8..64`, `byte` | 🔧 needs lib patch | `$key` writes fine; only the reverse `to(string, intXX)` overload is missing. Mechanical to add |
| `bool` | 🔧 needs lib patch | `$` → "true"/"false"; add `parseBool` overload |
| `char` | 🔧 needs lib patch | add 1-char overload |
| `enum` | 🔧 needs lib patch | `$` → symbol name; add `parseEnum` (named) or ordinal overload. Watch holey enums |
| `distinct <scalar>` | 🔧 needs lib patch | unwrap to base scalar (broker already unwraps distinct elsewhere) |
| `object` / `tuple` / `ref` / `seq` / `array` / any composite | ❌ **cannot be supported** | wire format forces each key through `$key` into a single CBOR **text-string** map key — not reversible for composites. Independently, target containers reject them: Rust `HashMap` needs `Eq+Hash`, Go `map` needs *comparable* (slices/maps aren't), C++ `unordered_map` needs a `std::hash` specialization |

**Two layers of restriction, both must pass:**
1. *Codec layer* — key must survive `$key` → text → `to(text, K)`. Composites fail
   irreversibly here.
2. *Target-language layer* — even a representable key must satisfy the foreign
   container's key bound (Rust `Eq+Hash`, Go comparable, C++ hashable). This is
   why `float` is technically codec-OK but practically rejected.

**Recommended supported set:**
- **Without any upstream patch:** `string` only (plain `int` works but its
  platform-dependent width makes it unsafe to expose over FFI — avoid).
- **With a small `nim-cbor-serialization` patch (D2):** `string`, sized ints
  `int8..64` / `uint8..64` / `byte`, `bool`, `char`, `enum`, and `distinct` of
  any of those. This is the recommended target — the patch is purely additive
  `to()` overloads (`$key` already serializes them today).
- **Never:** `float` keys, and any composite (`object`/`tuple`/`seq`/`ref`) key.

### Other notes that drive design

1. **`int`/`float`/`uint` keys (⚠) are the real cost.** The Nim codec emits
   text keys; jsoncons / serde / fxamacker / cbor2 will see a map whose keys are
   text strings. A generated `unordered_map<int64_t, V>` cannot deserialize a
   text-keyed CBOR map directly — the wrapper must (a) decode to a string-keyed
   intermediate and convert, or (b) we fix the Nim side to emit integer keys.
2. **`float` keys (✗)** are a bad idea regardless — Rust `HashMap` can't key on
   `f64` (no `Eq`/`Hash`); C++ `unordered_map<double>` is legal but
   semantically fragile. Recommend **disallowing float keys**.
3. **Ordering (`OrderedTable`)** survives only into Python `dict`. C++
   `unordered_map`, Rust `HashMap`, Go `map` are unordered. If order matters,
   the cross-language contract cannot honor it without switching targets to
   ordered/sorted containers (`std::map`, `BTreeMap`) — and even then it becomes
   *sorted*, not *insertion* order. Recommend: **document `OrderedTable` order as
   not preserved across FFI**, or map it to a `seq[(K,V)]` of pairs if order is
   a hard requirement.
4. **Value `V` recursion is free** — it reuses the existing seq/object recursion.
   Nested `Table[K, seq[Obj]]`, `Table[K, Table[...]]` all fall out of the
   recursive mapper, *provided* nested object value types get registered by
   `api_type_resolver` (new two-param branch must descend into `V`, and `K` when
   it's a registered scalar).

---

## 3. How CBOR handles it — envelope question answered

**No envelope is required.** `cbor_serialization/std/tables.nim`:

```nim
proc writeImpl(writer: var CborWriter, value: TableType) =
  writer.beginObject()
  for key, val in value:
    writer.writeField $key, val      # <-- key stringified
  writer.endObject()

proc readImpl(reader: var CborReader, value: var TableType) =
  for key, val in readObject(reader, string, ValueType):
    value[to(key, KeyType)] = val     # <-- to() supports int/float/string only
```

So a `Table` is a first-class CBOR map (major type 5). The only library work is:

- `api_cbor_codec.nim` must `import cbor_serialization/std/tables` (and re-export,
  mirroring the existing `std/options as cbor_options` line). Without it the
  `read`/`write` bindings are not in scope and any `Table` field fails to compile.

⚠ **Wire fidelity caveat (repeat of §2.1):** keys go out as **text strings**
even for integer keys. This is *self-consistent* for a Nim↔Nim round-trip but
**not canonical CBOR** and not what a hand-written `map<int,V>` consumer expects.
Two policies (pick one in §4).

---

## 4. Decision points needing your call

| # | Decision | Options | Recommendation |
|---|----------|---------|----------------|
| D1 | Supported key types | (a) string only · (b) string + integer · (c) + float/enum/bool (needs lib patch) | **(b)** — covers the real use cases, no upstream patch |
| D2 | Integer-key wire format | (a) accept text keys, convert in each wrapper · (b) patch `nim-cbor-serialization` to emit/parse CBOR integer keys | **(b) if we own the repo** (we have the local checkout) — cleaner CBOR, simpler wrappers, but touches a second repo + its tests |
| D3 | `OrderedTable` ordering | (a) document as not preserved · (b) map to `seq[(K,V)]` pairs when order matters | **(a)** for the container; offer pairs-seq as the escape hatch |
| D4 | Scope of containers | `Table` only · `+OrderedTable` · `+HashSet` | `Table` + `OrderedTable` now; `HashSet` as a follow-up |
| D5 | Distinct/alias key types | resolve through to base scalar, or reject | resolve like the existing distinct-unwrap path |

---

## 5. Implementation cost (assuming D1=b, D2=b, D3=a, D4=Table+OrderedTable)

| Area | Work | Size |
|------|------|------|
| `api_cbor_codec.nim` | add `std/tables` import + re-export | XS |
| `api_schema.nim` | `ApiFieldDef`: `isTable`, `tableKeyType`, `tableValueType`; extend `makeFieldDef` string parser; add `isTableType`/key-validation helper | S |
| `api_type_resolver.nim` | two-param `Table[` branch in `scanTypeNode` + `collectNestedTypeNodes` → register object `V` (and reject object `K`) | S |
| `api_cbor_descriptor.nim` | runtime descriptor variant for map fields (discovery API) | S |
| `api_codegen_cbor_hpp.nim` | `nimTypeToCppType` table branch → `std::unordered_map<K,V>`; jsoncons traits already auto-handle maps | S |
| `api_codegen_cbor_py.nim` | `nimTypeToPyHint` → `Dict[K,V]`; cbor2 auto | XS |
| `api_codegen_cbor_rust.nim` | `nimTypeToRustHint` → `HashMap<K,V>`; serde auto; add `use std::collections::HashMap` | S |
| `api_codegen_cbor_go.nim` | `nimTypeToGoCborHint` → `map[K]V`; fxamacker auto | S |
| `api_codegen_cbor_cddl.nim` | `nimTypeToCddl` → `{ * K => V }` | XS |
| **`nim-cbor-serialization`** (D2=b) | patch `std/tables.nim` writer to emit typed keys (int→CBOR int) + reader to accept them; **its own tests** | **M, separate repo** |
| Parity test lib | add `Table[string,_]`, `Table[int,_]`, `Table[_,Object]`, nested cases to `test/typemappingtestlib/` + the C++/Py/Rust/Go test harnesses (`rust_test/`, `go_test/`) | **M — the bulk of the effort** |
| Examples | add a map field to `examples/ffiapi/nimlib/mylib.nim` + 5 consumer examples | S |
| Docs | update AGENTS.md type-matrix lines; `Broker_FFI_API.md`; this doc → final | S |

**Biggest cost is not the codegen branches (each is a few lines mirroring seq);
it is (1) the parity-matrix test expansion across 4 languages × orc/refc ×
debug/release, and (2) the optional `nim-cbor-serialization` key-encoding patch
if you want canonical integer keys (D2=b).**

### Risks / gotchas
- **refc vs orc:** `Table` is GC-managed; inside the FFI lane it lives only on
  the Nim side (encoded to CBOR bytes before crossing the ABI), so no cross-FFI
  ownership question arises — same lifetime story as `seq`. Verify under refc
  anyway (the codec allocates during encode/decode).
- **Empty map vs absent field:** decide whether `{}` and "field omitted" differ;
  cbor2/serde/fxamacker treat an absent map field differently from an empty one.
- **Key collisions after stringification (D2=a only):** `Table[int,V]` with keys
  `5` and a `Table[string,V]` "5" would alias — only a problem if D2=a; D2=b
  removes it.
- **Go `map` nil vs empty**, **Rust `HashMap` vs `BTreeMap`** (no order),
  **C++ `unordered_map` no order** — all already captured in §2.3.

---

## 6. Suggested sequencing (once a decision is made)

1. Land the D2 key-encoding decision in `nim-cbor-serialization` first (if D2=b),
   with its own round-trip test, and bump the `requires` pin.
2. `api_cbor_codec` import + `api_schema`/`api_type_resolver` recognition →
   compile a single `Table[string,int]` field end-to-end (Nim-only) before any
   wrapper work.
3. C++ + Python wrappers (cheapest, jsoncons/cbor2 auto-handle maps) → green
   parity test for those two.
4. Rust + Go wrappers → full matrix.
5. CDDL + discovery descriptor + examples + docs.
