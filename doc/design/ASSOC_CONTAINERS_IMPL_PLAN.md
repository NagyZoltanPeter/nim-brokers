# Implementation Plan — `Table[K,V]` FFI Support

Branch: `api-support-assoc-containers-nolibpatch`
Companion to: `doc/design/ASSOC_CONTAINERS_PLAN.md` (research/decision doc)
Status: **implemented — no dependency change; full scalar-key coverage in all four wrappers**.

### Implementation status

> **Two branches exist:**
> - `api-support-associative-containers` — patches `nim-cbor-serialization`
>   (`std/tables.nim`). Preserved, but the dependency change was deemed
>   unacceptable.
> - **`api-support-assoc-containers-nolibpatch`** (this branch) — delivers the
>   **same** functionality with **no dependency change**. The Table CBOR codec
>   lives in `brokers/internal/api_cbor_tables.nim` and supplies the `write` /
>   `read` hooks through the library's public `reader`/`writer` API; the
>   library's own `cbor_serialization/std/tables` binding is *not* imported, so
>   it never reaches the int/float/string-only `to()` overloads. The
>   `cbor_serialization` pin stays at its upstream release.

| Phase | Result (no-libpatch branch) |
|-------|------------------------------|
| 1 — Table CBOR codec | ✅ `brokers/internal/api_cbor_tables.nim`; text keys, int8..64/char/enum(ordinal)/distinct; `test/test_api_table_codec.nim` round-trips 9 shapes against the **upstream** lib |
| 2 — brokers recognition + key validation | ✅ recognition test + baseline/mt Table fields compile |
| 3 — **full key coverage, all four wrappers** | ✅ Python (`_encode`/`_decode` key conv), C++ (`<Name>__wire` + custom `json_type_traits`), Rust (`cbor_strkey_map` serde adapter + enum `Display`/`FromStr`), Go (generated `Marshal`/`UnmarshalCBOR`) |
| 4 — same wrappers, every scalar key (string/int8..64/char/enum/distinct) | ✅ `test_map_result_all_key_flavors` green in all four parity harnesses |
| 5 — CDDL `{* tstr => V}`, refc matrix, docs | ✅ this commit |

Verified across **orc + refc** against the **unpatched** dependency:
`runTypeMapTestLib{Py 86, Cpp 133, Rust 133, Go 133}` + `nimble testApi` green.
Examples (`mylib` + 5 consumers) intentionally untouched — the parity testlib is
the authoritative coverage. **No dependency change, no `nimbledeps` patch, no
version-pin bump required.**

---

## 1. Locked scope

- **Container:** `Table[K, V]` only. `OrderedTable` **excluded** (order loss
  accepted by decision; if added later it aliases to `Table` codegen).
- **Key types `K` (exactly this set):**
  `string`, `int8`, `int16`, `int32`, `int64`, `char`, `enum`, `distinct <scalar>`.
  Explicitly **out:** plain `int`/`uint*` (platform-width — unsafe over FFI),
  `bool`, `float`, and every composite (`object`/`tuple`/`seq`/`ref`) — see
  research doc §2 for the "why".
- **Value type `V`:** unrestricted — reuses the existing `seq`/object recursion
  (primitive, string, object, nested `seq`, nested `Table`).

## 2. Architecture decision — text keys + wrapper conversion (Strategy A) ✅ CHOSEN

> **Plan correction (verified against `writer.nim`):** the original §2 premise —
> that `std/tables.nim` could emit native typed keys via `writeValue(key)` — is
> **false**. The writer's state machine locks the map-key slot to text strings:
> `beginElement` (`writer.nim:108`) does `doAssert not w.wantName`, and after
> `beginObject` `wantName = true`; only `writeName` (string → `CborMajor.Text`)
> services the key slot. Emitting typed keys would require a **core-writer**
> change (a new `writeKey`). Per decision, we do **not** touch the core writer.

Chosen approach — keys travel on the wire as **CBOR text strings** in all cases:
- `string` → itself; `int8..64` → decimal text; `char` → 1-char text;
  `enum` → symbol name text; `distinct T` → text of base `T`.
- All codec changes stay inside `cbor_serialization/std/tables.nim` (no core
  `writer.nim`/`reader.nim` change).
- **Each of the 4 wrappers converts** the text key ↔ its declared typed key for
  non-string `K` (`int*`/`char`/`enum`/`distinct`). `string` keys are pass-through.

Trade-off accepted: non-canonical wire for non-string keys (e.g. int key `5`
encoded as text `"5"`) and per-wrapper key-conversion code, in exchange for zero
core-writer risk. Foreign maps are still **typed** (`unordered_map<int32_t,V>`,
`Dict[int,V]`, `HashMap<i64,V>`, `map[int64]V`) — the conversion happens in the
generated decode/encode path.

## 3. Step 0 — verification spike (do first, ~½ day)

Before touching brokers, prove the codec patch in isolation in
`~/dev/status/nim-cbor-serialization`:

1. Hand-write the new `writeImpl`/`readImpl` (sketch in §4) in a scratch test.
2. Round-trip `Table[int32, string]`, `Table[string, int32]`,
   `Table[MyEnum, Obj]`, `Table[char, int]`, `Table[MyDistinctInt, V]`.
3. Confirm the writer emits typed keys (inspect bytes: int key = major 0/1, not
   text major 3) and `readObject(r, K, V)` reconstructs them.
4. Confirm `mixin` picks up a caller-defined `writeValue`/`readValue` for the
   distinct key type.

**Gate:** all five round-trip byte-exact. If the writer cannot emit non-string
keys cleanly, fall back to Strategy A (research doc §4 D2a) and revisit scope.

## 4. `nim-cbor-serialization` patch (`cbor_serialization/std/tables.nim` only)

Keep the text-key write path; make it distinct-aware; add `to()` read overloads
for the §1 key set. No core `writer.nim`/`reader.nim` change. Sketch:

```nim
import std/[strutils, typetraits], stew/shims/tables, ../../cbor_serialization/[reader, writer]

func keyToStr[K](key: K): string =
  when K is distinct: $distinctBase(key, recursive = true)  # base may be int/enum/char/string
  else: $key

proc writeImpl(writer: var CborWriter, value: TableType) {.raises: [IOError].} =
  writer.beginObject()
  for key, val in value:
    writer.writeField keyToStr(key), val   # key always text
  writer.endObject()

# read side — string keys, then convert to declared KeyType:
template to*(a: string, b: type int8): int8 = parseIntBounded[int8](a)   # +int16/32/64
template to*(a: string, b: type char): char = parseCharKey(a)           # len==1 or ValueError
proc     to*[T: enum](a: string, b: type T): T = parseEnum[T](a)
proc     to*[T: distinct](a: string, b: type T): T = T(to(a, distinctBase(T, recursive = true)))
# parseIntBounded raises ValueError on overflow/garbage → caught by readImpl's try/except
```

- `readImpl` is unchanged from upstream: `readObject(reader, string, ValueType)`
  then `value[to(key, KeyType)] = val`.
- Range-check sized ints (`parseIntBounded` raises `ValueError`, already caught).
- **Overload-resolution risk:** the constrained generic procs (`T: enum`,
  `T: distinct`) must win over the catch-all `to(a, b: typed)` error template —
  verify by compiling each key type (this is what Step 0 / §3 proves).
- Backward-compatible: `string`/`int`/`float` keys behave exactly as before;
  `keyToStr` only adds the distinct case.
- Add the lib's own round-trip tests; bump `brokers.nimble`
  `requires "cbor_serialization >= <new>"` + nix pin once tagged.

## 5. brokers — type recognition

| File | Change | Pre-edit |
|------|--------|----------|
| `brokers/internal/api_cbor_codec.nim` | `import cbor_serialization/std/tables` + re-export (mirror the `std/options as cbor_options` line) | — |
| `brokers/internal/api_schema.nim` | `ApiFieldDef`: add `isTable`, `tableKeyType`, `tableValueType`; extend `makeFieldDef` to parse `"Table[K, V]"` (2-param split, comma-aware); add `isAllowedTableKey(t): bool` (the §1 set) | `gitnexus_impact({target:"makeFieldDef", direction:"upstream"})` |
| `brokers/internal/api_type_resolver.nim` | new `nnkBracketExpr len==3 && $[0]=="Table"` branch in `scanTypeNode` + `collectNestedTypeNodes`: descend into `V` to register object value types; if `K` is enum/distinct register it; **reject** composite/float/bool/plain-int `K` with a clear compile error | `gitnexus_impact({target:"scanTypeNode"...})` |

Key-validation error message must name the field + the offending key type and
point to the supported set.

## 6. brokers — wrapper codegen (one branch per file, mirrors `seq`)

Add a shared 2-param unwrap helper (`unwrapTable(t) -> (K, V)`), then a
`startsWith("table[")` branch in each mapper:

| File | Proc | Emit | Key/container note |
|------|------|------|--------------------|
| `api_codegen_cbor_hpp.nim` | `nimTypeToCppType` | `std::unordered_map<Kc, Vc>` | enum key OK (C++14 `std::hash<enum>`); distinct→base scalar; `#include <unordered_map>` |
| `api_codegen_cbor_py.nim` | `nimTypeToPyHint` | `Dict[Kpy, Vpy]` | enum key → `IntEnum`; cbor2 auto |
| `api_codegen_cbor_rust.nim` | `nimTypeToRustHint` | `HashMap<Kr, Vr>` | enum key needs `#[derive(Hash,Eq,PartialEq)]`; `use std::collections::HashMap` |
| `api_codegen_cbor_go.nim` | `nimTypeToGoCborHint` | `map[Kg]Vg` | all keys comparable; enum is int-alias |
| `api_codegen_cbor_cddl.nim` | `nimTypeToCddl` | `{ * K => V }` | — |
| `api_cbor_descriptor.nim` | runtime descriptor | map-kind field for discovery API | key + value type tags |

Key-type sub-mapping (`Kc`/`Kpy`/`Kr`/`Kg`): `string`→native string; `int8..64`→
sized int; `char`→`char`/`int`/`u8`/`byte` per lang; `enum`→generated enum type;
`distinct T`→mapped base `T`.

## 7. Examples + tests (the bulk of the effort)

- **typemappingtestlib** (`test/typemappingtestlib/`): add fields
  `Table[string, int32]`, `Table[int32, string]`, `Table[MyEnum, Obj]`,
  `Table[char, int32]`, `Table[MyDistinctId, int64]`, and one nested
  `Table[string, seq[Obj]]`. Extend the C++/Py/Rust/Go parity harnesses
  (`rust_test/`, `go_test/`, `test_typemappingtestlib.{cpp,py}`) to assert
  round-trip + key/value fidelity.
- **examples**: add one map field to `examples/ffiapi/nimlib/mylib.nim` and
  exercise it in `example/main.c` (opaque CBOR), `cpp_example`, `python_example`,
  `rust_example`, `go_example`.
- **MM matrix:** run orc + refc, debug + release, per AGENTS.md tasks.

## 8. Verification gates (per CLAUDE.md "goal-driven")

1. Step 0 spike round-trips green (codec only).
2. `nim c` a single `Table[string,int32]` field end-to-end (Nim-only, no wrapper).
3. `nimble testApi` green.
4. `nimble runTypeMapTestLibCpp` + `...Py` green.
5. `nimble runTypeMapTestLibRust` + `...Go` green.
6. `nimble runFfiExample{Cpp,Py,Rust,Go}` green.
7. `nimble nphall` clean; `gitnexus_detect_changes()` shows only intended symbols.

## 9. Risks / must-check

- **`char` codec encoding** — confirm `writeValue`/`readValue[char]` exist and
  agree on int vs text-byte; add overload if missing.
- **Holey/non-contiguous enums** — ordinal-on-wire is fine; ensure foreign enum
  `From<i32>`/decode handles unknown ordinals (error, not UB).
- **Distinct key `$`/codec** — relies on the broker registering the distinct's
  `writeValue`/`readValue`; verify the resolver registers distinct *key* types,
  not just value/field types.
- **Empty map vs absent field** — define and test `{}` vs omitted across cbor2/
  serde/fxamacker (they differ).
- **refc vs orc** — `Table` is GC-managed but lives only Nim-side (encoded to
  bytes before the ABI), same lifetime story as `seq`; run the refc matrix.
- **Enum key hashing in C++/Rust** — add the required hash/derive (§6 notes).

## 9b. Per-language key conversion (full coverage)

The Nim wire emits **text keys for all key types** (int→"5", enum→ordinal "0",
char→"a", distinct→base text) — the `cbor_serialization` writer can only put a
string in a CBOR map's key slot, and patching that core was rejected. Foreign
CBOR libs decode these as **string** keys and do **not** auto-convert to a
non-string key type (confirmed empirically in all three: C++ jsoncons errors
`Cannot convert to integer`; Rust ciborium decode fails; Go fxamacker silently
drops the entries). Each wrapper therefore converts text ⇄ typed key in
generated code:

- **Python** (`cbor2`): `_encode`/`_decode` helpers convert per key —
  `int(_k)`, `Priority(int(_k))`, `str(int(_k))`.
- **C++** (`jsoncons`): a struct with a non-string-keyed map gets a string-keyed
  `<Name>__wire` mirror (`JSONCONS_ALL_MEMBER_TRAITS`) plus a hand-written
  `json_type_traits<Json, Name>` that delegates field handling to the wire and
  converts only the map keys (`std::stoll` / `std::to_string`, char via the
  first byte; enum key types namespace-qualified).
- **Rust** (`serde`/`ciborium`): a generic `cbor_strkey_map` `#[serde(with)]`
  adapter (emitted when needed) converts via `Display`/`FromStr`; generated
  enums gain `Display` (ordinal), `FromStr`, and `Hash`.
- **Go** (`fxamacker`): structs with non-string-keyed maps get generated
  `Marshal`/`UnmarshalCBOR` that round-trip through a string-keyed wire struct
  (`strconv` both ways).

`string`/`char` keys map to the wrapper's native string type and need no
adapter (except C++, where `char` is a distinct key handled by the same path).

**Result:** `test_map_result_all_key_flavors` (string / int32 / char / enum /
distinct keys) is green in all four parity harnesses, orc + refc.

## 10. Sequencing

Step 0 spike → §4 codec patch (+pin) → §5 recognition (compile one field) →
§6 C++ & Python (cheapest, auto-map) → §6 Rust & Go → CDDL + descriptor →
§7 examples + full parity matrix → §8 gates → docs (AGENTS.md type matrix,
`Broker_FFI_API.md`, mark both assoc-container docs final).
