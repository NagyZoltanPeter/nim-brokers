# Broker FFI API — Type-support matrix

Authoritative reference for which Nim type patterns are supported across
each foreign-language wrapper (C++ / Python / Rust / Go). Cells are
evidence-backed: ✅ entries are validated by the parity test suite
(`runTypeMapTestLibCborCpp`, `runTypeMapTestLibCborPy`,
`runTypeMapTestLibCborRust`, `runTypeMapTestLibCborGo`); ❌ entries are
confirmed broken by direct probe; ❓ entries are untested.

**Pure C is not in the matrix.** The typed-C wrapper is deferred — see
`doc/design/CBOR_Refactoring.md` §10. Pure-C consumers currently see
only the raw 11-function CBOR ABI and must hand-encode payloads against
it.

## ABI mode

CBOR is the only FFI mode. Activate codegen with `-d:BrokerFfiApi`. The
native per-type C codegen was retired — see `doc/design/CBOR_Refactoring.md`.
The historical `-d:BrokerFfiApiNative` and transitional
`-d:BrokerFfiApiCBOR` flags no longer exist. Restrictions documented in
earlier revisions of this file that referenced `api_type.nim` /
`toCFieldType` / the `CItem` layout no longer apply — every such cell
has been re-probed and migrated to ✅ where the parity tests now lock
the behaviour in.

## Legend

| Mark | Meaning |
|---|---|
| ✅ | Works end-to-end. Validated by parity test. |
| ⚠️ | Compiles but defective; specific defect noted. |
| ❌ | Rejected at codegen or fails to compile. |
| ❓ | Untested — no library exercises this combination. |
| — | Not applicable. |

## Section 1 — Request RESULT field types

The field appears inside the `Result<T>` payload struct returned by a request method.

| Nim type | C++ | Py | Rust | Go |
|---|---|---|---|---|
| `bool` / `intN` / `uintN` / `byte` / `floatN` | ✅ | ✅ | ✅ | ✅ |
| `string` | ✅ | ✅ | ✅ | ✅ |
| `cstring` | ✅ | ✅ | ✅ | ✅ |
| `char` | ✅ | ✅ | ✅ | ✅ |
| Plain `enum` | ✅ | ✅ | ✅ | ✅ |
| `distinct intN` (incl. type aliases of primitives) | ✅ | ✅ | ✅ | ✅ |
| Object (all primitive/string fields) — used as the *whole result type* | ✅ | ✅ | ✅ | ✅ |
| Object (all primitive/string fields) — embedded as an *inline field* of another object | ✅ ¹ | ✅ ¹ | ✅ ¹ | ✅ ¹ |
| `seq[byte]` | ✅ | ✅ | ✅ | ✅ |
| `seq[primitive]` (e.g. `seq[int64]`) | ✅ | ✅ | ✅ | ✅ |
| `seq[string]` | ✅ | ✅ | ✅ | ✅ |
| `seq[Object]` (Object has prim/string fields only) | ✅ | ✅ | ✅ | ✅ |
| `seq[Object<seq>]` (the inner object contains its own `seq[T]`) | ✅ ² | ✅ ² | ✅ ² | ✅ ² |
| `array[N, primitive]` | ✅ | ✅ | ✅ | ✅ |
| `array[N, string]` | ✅ ³ | ✅ ³ | ✅ ³ | ✅ ³ |
| `array[N, Object]` | ✅ | ✅ | ✅ | ✅ |
| `Option[T]` (scalar / string / `seq[primitive]` / Object) | ✅ | ✅ | ✅ | ✅ |
| `tuple[a: T, b: U, ...]` (named) | ✅ | ✅ | ✅ | ✅ |

## Section 2 — Request PARAMETER types

The type appears in the request method signature on the *caller* side.

| Nim type | C++ | Py | Rust | Go |
|---|---|---|---|---|
| `bool` / `intN` / `uintN` / `byte` / `floatN` | ✅ | ✅ | ✅ | ✅ |
| `string` / `cstring` / `char` | ✅ | ✅ | ✅ | ✅ |
| Plain `enum` | ✅ | ✅ | ✅ | ✅ |
| `distinct intN` | ✅ | ✅ | ✅ | ✅ |
| Object as param (whole-object pass-by-value) | ✅ | ✅ | ✅ | ✅ |
| `seq[byte]` | ✅ | ✅ | ✅ | ✅ |
| `seq[primitive]` | ✅ | ✅ | ✅ | ✅ |
| `seq[string]` | ✅ | ✅ | ✅ | ✅ |
| `seq[Object]` (prim/string fields only) | ✅ | ✅ | ✅ | ✅ |
| `seq[Object<seq>]` | ✅ ² | ✅ ² | ✅ ² | ✅ ² |
| `array[N, primitive]` | ✅ ⁴ | ✅ ⁴ | ✅ ⁴ | ✅ ⁴ |
| `array[N, string]` | ✅ ³ | ✅ ³ | ✅ ³ | ✅ ³ |
| `array[N, Object]` | ✅ ⁵ | ✅ ⁵ | ✅ ⁵ | ✅ ⁵ |
| `Option[T]` (scalar / string / `seq[primitive]` / Object) | ✅ | ✅ | ✅ | ✅ |

## Section 3 — Event PAYLOAD field types

The field appears in an `EventBroker(API)` object — fired by Nim, delivered to a closure registered via `on_<event>`.

| Nim type | C++ | Py | Rust | Go |
|---|---|---|---|---|
| `bool` / `intN` / `uintN` / `byte` / `floatN` | ✅ | ✅ | ✅ | ✅ |
| `string` / `cstring` / `char` | ✅ | ✅ | ✅ | ✅ |
| Plain `enum` | ✅ | ✅ | ✅ | ✅ |
| `distinct intN` | ✅ | ✅ | ✅ | ✅ |
| `seq[primitive]` | ✅ | ✅ | ✅ | ✅ |
| `seq[string]` | ✅ | ✅ | ✅ | ✅ |
| `seq[Object]` (prim/string fields) | ✅ | ✅ | ✅ | ✅ |
| `seq[Object<seq>]` | ✅ ² | ✅ ² | ✅ ² | ✅ ² |
| `array[N, primitive]` | ✅ | ✅ | ✅ | ✅ |
| `array[N, string]` | ✅ ⁶ | ✅ ⁶ | ✅ ⁶ | ✅ ⁶ |
| `array[N, Object]` | ✅ ⁷ | ✅ ⁷ | ✅ ⁷ | ✅ ⁷ |

## Footnotes

1. **Object as inline field** works end-to-end on all wrappers.
   Validated by `test_nested_obj_inline_field` against the
   `NestedObjRequest` broker, whose result struct carries a `Tag`
   directly as a field (not via `seq` / `array` / `Option`). The
   wrappers emit the nested struct + its `JSONCONS_ALL_MEMBER_TRAITS`
   / dataclass / `#[derive(Deserialize)]` / cbor-tag registration
   inline and round-trip the values byte-identical.

2. **`seq[Object<seq>]` works end-to-end on all wrappers.** Validated
   by `test_list_inners_result_*`, `test_bulk_inners_param_roundtrip`,
   and `test_inners_updated_event` in the parity suite. `Inner` carries
   `seq[byte]` inside, then sits inside `seq[Inner]` on the outer
   broker — the very shape earlier revisions of this file marked ❌.
   The historical restriction was a side-effect of the retired native
   ABI's `CItem` layout requiring simple-ident field types; the CBOR
   codegen has no such restriction.

3. **`array[N, string]` works end-to-end on all wrappers.** Validated
   by `test_fixed_str_array_result` (§1) and `test_set_tags_array_param`
   (§2). Wrappers translate `array[N, string]` to their
   variable-length list types (`std::vector<std::string>`,
   `List[str]`, `Vec<String>`, `[]string`); the Nim side range-checks
   the length on decode. If the wrapper passes a length other than
   `N` the broker returns a clean `err(...)`.

4. **`array[N, primitive]` as request param** — validated by
   `test_sum_prim_array_param` for `array[4, int32]`. Same
   length-on-decode semantics as footnote 3 — the wrapper passes a
   length-N vector / list / slice and the Nim side validates.

5. **`array[N, Object]` as request param** works end-to-end on all
   wrappers. Validated by `test_set_slots_obj_array_param`: the
   `SetSlotsRequest` broker accepts a fixed-size array of `Slot`
   structs, joins their `name` fields, and returns the result —
   exercising both the wrapper-side serialization of an array of
   nested objects and the Nim-side decode + provider invocation.

6. **`array[N, string]` in events** works end-to-end on all wrappers.
   Validated by `test_str_array_event` against the `StrArrayEvent`
   broker (fired by `TriggerStrArrayRequest`). Wrappers deliver the
   four strings as their natural list type (`std::span<const
   std::string>`, `List[str]`, `Vec<String>`, `[]string`).

7. **`array[N, Object]` in events** — validated by
   `test_fixed_obj_array_event`. The wrappers deliver the slots as a
   length-N list/span of the typed element struct.

## Recommended idioms

To stay safely inside the green cells:

1. **Prefer `seq[T]` over `array[N, T]` when N varies between
   instances.** Both work; `seq[T]` is naturally variable-length while
   `array[N, T]` enforces a runtime length check on decode. Use the
   array form when N is a true protocol-level invariant.
2. **Composite object fields are fine.** A registered Object can carry
   `seq[byte]`, `seq[T]`, `array[N, T]`, `Option[T]`, or nested objects
   in any combination. The earlier "keep object field types flat"
   guidance was a native-ABI artifact and no longer applies.
3. **Nested types auto-register.** Plain Nim `object` / `enum` /
   `distinct` types referenced in a broker signature are discovered
   and registered automatically — no `ApiType` annotation needed.

## Worked example: `WakuMessage`

A common shape worth analysing in detail:

```nim
type ContentTopic* = string  # or `distinct string`; same answer
type Timestamp* = distinct int64

type WakuMessage* = object
  payload*: seq[byte]
  contentTopic*: ContentTopic
  meta*: seq[byte]
  version*: uint32
  timestamp*: Timestamp
  ephemeral*: bool
  proof*: seq[byte]
```

Field-by-field, every type is in a green row of all three sections
(`seq[byte]`, string-aliased, `uint32`, `distinct int64`, `bool`).

| Position | Status | Notes |
|---|---|---|
| Request **result** type — `Future[Result[WakuMessage, string]]` | ✅ | All fields green; same shape as the validated `Tag`-style objects. |
| Event **payload** — `EventBroker(API): type WakuMessageReceived = object` with these fields | ✅ | Same shape as `TagSeqEvent` / `PrimScalarEvent`, all green in the parity matrix. |
| Request **parameter** — `proc signature(msg: WakuMessage)` | ✅ | Object-as-param is supported on all wrappers (Section 2). |
| Field of *another* registered Object | ✅ | Inline-nested Object validated by `test_nested_obj_inline_field` (footnote 1). |
| `seq[WakuMessage]` — batched delivery | ✅ | Covered by the `seq[Object<seq>]` row — `WakuMessage` carries `seq[byte]` fields, the exact composite-inside-element shape (footnote 2). |

```rust
// Rust — pass the whole object directly
let r = lib.send(msg.clone())?;
```

```python
# Python — identical
r = lib.send(msg)
```

```cpp
// C++ — identical
auto r = lib.send(msg).value();
```

```go
// Go — identical
r, err := lib.Send(msg)
```

## Maintenance

When adding a probe to close one of the `❓` cells:

1. Add the type and a request/event using it to
   `test/typemappingtestlib/typemappingtestlib.nim`.
2. Add a corresponding assertion to the parity tests:
   - `test/typemappingtestlib/test_typemappingtestlib.cpp`
   - `test/typemappingtestlib/test_typemappingtestlib.py`
   - `test/typemappingtestlib/rust_test/src/main.rs`
   - `test/typemappingtestlib/go_test/main.go`
3. Run all four `runTypeMapTestLibCbor*` tasks (Cpp / Py / Rust / Go).
4. Update the relevant cell in this document with the result.

When a defect is found, document it in the footnotes with file/line
evidence, **leave the failing probe out of the live test code** (it
would block CI), and keep the matrix entry accurate.
