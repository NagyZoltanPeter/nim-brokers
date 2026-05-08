# Broker FFI API — Type-support matrix

This document is the authoritative reference for which Nim type patterns are supported across each foreign-language wrapper (C / C++ / Python / Rust) in each FFI mode (native / CBOR). Cells are evidence-backed: ✅ entries are validated by the parity test suite (`runTypeMapTestLibCborPy`, `runTypeMapTestLibCborCpp`, `runTypeMapTestLibCborRust`, `runTypeMapTestLibRust`, `testFfiApi`, `testFfiApiCpp`); ❌ entries are confirmed broken by direct probe; ❓ entries are untested.

## Legend

| Mark | Meaning |
|---|---|
| ✅ | Works end-to-end. Validated by parity test. |
| ⚠️ | Compiles in some configurations but defective; specific defect noted. |
| ❌ | Rejected at codegen or fails to compile. |
| ❓ | Untested — no library exercises this combination. |
| — | Not applicable. |

**Mode columns:**

- **N** = native FFI (`-d:BrokerFfiApiNative`) — typed C ABI; one C function per request, one trampoline type per event.
- **C** = CBOR FFI (`-d:BrokerFfiApiCBOR`) — fixed 11-function ABI; payloads are CBOR-encoded.

## Section 1 — Request RESULT field types

The field appears inside the `Result<T>` payload struct returned by a request method.

| Nim type | C–N | C–C | C++–N | C++–C | Py–N | Py–C | Rust–N | Rust–C |
|---|---|---|---|---|---|---|---|---|
| `bool` / `intN` / `uintN` / `byte` / `floatN` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `string` (→ `char*` / `std::string` / `str` / `String`) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `cstring` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `char` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Plain `enum` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `distinct intN` (incl. type aliases of primitives) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Object (all primitive/string fields) — used as the *whole result type* | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Object (all primitive/string fields) — embedded as an *inline field* of another object | ❓ ¹ | ❓ ¹ | ❓ ¹ | ❓ ¹ | ❓ ¹ | ❓ ¹ | ❓ ¹ | ❓ ¹ |
| `seq[byte]` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `seq[primitive]` (e.g. `seq[int64]`) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `seq[string]` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `seq[Object]` (Object has prim/string fields only) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `seq[Object<seq>]` (the inner object contains its own `seq[T]`) | ❌ ² | ❌ ² | ❌ ² | ❌ ² | ❌ ² | ❌ ² | ❌ ² | ❌ ² |
| `array[N, primitive]` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `array[N, string]` | ❌ ³ | ❌ ³ | ❌ ³ | ❌ ³ | ❌ ³ | ❌ ³ | ❌ ³ | ❌ ³ |
| `array[N, Object]` | ⚠️ ⁴ | ⚠️ ⁴ | ⚠️ ⁴ | ⚠️ ⁴ | ✅ | ✅ | ❌ ⁵ | ✅ |
| `Option[T]` | ❓ ⁶ | ❓ ⁶ | ❓ ⁶ | ❓ ⁶ | ❓ ⁶ | ❓ ⁶ | ❓ ⁶ | ❓ ⁶ |

## Section 2 — Request PARAMETER types

The type appears in the request method signature on the *caller* side.

| Nim type | C–N | C–C | C++–N | C++–C | Py–N | Py–C | Rust–N | Rust–C |
|---|---|---|---|---|---|---|---|---|
| `bool` / `intN` / `uintN` / `byte` / `floatN` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `string` / `cstring` / `char` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Plain `enum` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `distinct intN` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Object as param (whole-object pass-by-value) | ❌ ⁷ᵃ | ✅ | ❌ ⁷ᵃ | ✅ | ❌ ⁷ᵇ | ✅ | ❌ ⁷ᶜ | ✅ |
| `seq[primitive]` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `seq[string]` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `seq[Object]` (prim/string fields only) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `seq[Object<seq>]` | ❌ ² | ❌ ² | ❌ ² | ❌ ² | ❌ ² | ❌ ² | ❌ ² | ❌ ² |
| `array[N, primitive]` | ❓ ⁸ | ❓ ⁸ | ❓ ⁸ | ❓ ⁸ | ❓ ⁸ | ❓ ⁸ | ❓ ⁸ | ❓ ⁸ |
| `array[N, string]` | ❌ ³ | ❌ ³ | ❌ ³ | ❌ ³ | ❌ ³ | ❌ ³ | ❌ ³ | ❌ ³ |
| `array[N, Object]` | ❓ ⁸ | ❓ ⁸ | ❓ ⁸ | ❓ ⁸ | ❓ ⁸ | ❓ ⁸ | ❓ ⁸ | ❓ ⁸ |

## Section 3 — Event PAYLOAD field types

The field appears in an `EventBroker(API)` object — fired by Nim, delivered to a closure registered via `on_<event>`.

| Nim type | C–N | C–C | C++–N | C++–C | Py–N | Py–C | Rust–N | Rust–C |
|---|---|---|---|---|---|---|---|---|
| `bool` / `intN` / `uintN` / `byte` / `floatN` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `string` / `cstring` / `char` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Plain `enum` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `distinct intN` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `seq[primitive]` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `seq[string]` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `seq[Object]` (prim/string fields) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `seq[Object<seq>]` | ❌ ² | ❌ ² | ❌ ² | ❌ ² | ❌ ² | ❌ ² | ❌ ² | ❌ ² |
| `array[N, primitive]` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `array[N, string]` | ❓ ⁹ | ❓ ⁹ | ❓ ⁹ | ❓ ⁹ | ❓ ⁹ | ❓ ⁹ | ❓ ⁹ | ❓ ⁹ |
| `array[N, Object]` | ❓ ⁹ | ❓ ⁹ | ❓ ⁹ | ❓ ⁹ | ❓ ⁹ | ❓ ⁹ | ❓ ⁹ | ❓ ⁹ |

## Footnotes

1. **Object as inline field** — e.g. `type Outer = object; inner: Inner` with both registered. The CItem layout machinery would just nest, and probably works on every backend, but no test exercises it. Treat as untested until a probe is added.

2. **`seq[Object<seq>]` — inner object contains a composite field.** Fails at the Nim type registry. `api_type.nim:90` calls `toCFieldType(ident(ftype))` where `ftype` is the field-type *name string*. For `seq[Tag]` this produces `ident("seq[Tag]")`, which Nim rejects as an invalid identifier. The CItem layout machinery requires field types to be simple identifiers. The inner type can't even register, so the outer composite never reaches codegen. Affects every wrapper equally.

3. **`array[N, string]` — request broker codegen rejects.** `api_request_broker.nim:532` does a typed object construction that expects `array[N, cstring]`, but the Nim source declares `array[N, string]`. The implicit `string → cstring` conversion that works for plain string fields isn't applied inside arrays. Fails compilation before reaching any wrapper.

4. **`array[N, Object]` C/C++ defects:**
   - The generated `.h` emits `Inner items[N]` but `Inner` is undeclared in C scope — only `InnerCItem` is. Empirical proof: `error: unknown type name 'Inner'` when the C++ test includes the header.
   - The `.hpp` adopt loop uses `std::copy(c.items, c.items + N, r.items.begin())` between layouts that don't match — `InnerCItem.label` is `char*`, `Inner.label` is `std::string`. Even if the header were patched, runtime behaviour would be undefined.

5. **`array[N, Object]` Rust native** — explicit `// TODO(rust-codegen)` stub. The codegen's `rsTypeMappable` rejects array elements that aren't primitive.

6. **`Option[T]`** — the CBOR Python codegen handles `option[T]` syntactically. Native side: probably absent. No end-to-end test exists. Treat as untested.

7. **Object as request param (whole-object pass-by-value)** — empirically validated by the `ObjParamRequest` probe in `typemappingtestlib`, gated to CBOR mode (the broker is wrapped in `when defined(BrokerFfiApiCBOR):` because native builds fail at compile or runtime).
   - **7a) C / C++ native:** the generated `.h` emits `Tag tag` in the function signature but `Tag` is undeclared at C scope (only `TagCItem` is). Empirical: `typemappingtestlib.h:187:67: error: unknown type name 'Tag'` when the C++ test includes the header. Same root cause as footnote 4.
   - **7b) Python native:** the generated wrapper sets `argtypes = [..., TagCItem]` correctly, but the method body passes the public `Tag` dataclass directly without converting. Empirical: `ctypes.ArgumentError: argument 2: <class 'TypeError'>: expected TagCItem instance instead of Tag` at runtime.
   - **7c) Rust native:** the codegen's `rsTypeMappable` rejects whole-Object params and emits `// TODO(rust-codegen)`.
   - **CBOR (all four wrappers): ✅** — validated by `runTypeMapTestLibCborRust` (43/43 incl. ObjParamRequest), `runTypeMapTestLibCborPy` (53 tests), `runTypeMapTestLibCborCpp` (101 tests). CBOR mode encodes the object as a CBOR map; no per-language CItem expansion required.
   - **Workaround for native mode: flatten the struct into individual fields** (see worked example below).

8. **`array[N, T]` as request param** — every test exercises `array[N, T]` only as a *result* field, never as a parameter. The Python codegen has a code path (`isArrayTypeNode(paramType)` → `ctypes.POINTER(ctElem)`) but no end-to-end coverage. For `string` and `Object` element types, the same defects as the result-side rows above almost certainly recur.

9. **`array[N, string]` / `array[N, Object]` in events** — the event codegen path is independent from the request path, so it might not hit defect #3. The C-header defect from #4 is shared, however, since the event callback signature embeds the same C type expressions. No empirical data; treat as suspect.

## Recommended idioms

To stay safely inside the green cells:

1. **Use `seq[T]` over `array[N, T]` when the element is `string` or an `Object`.** Fixed-size arrays of composite elements have unfixed bugs (rows 14–15 of Section 1). Fixed-size arrays of primitives are perfectly safe.
2. **Flatten objects in request parameter lists** rather than passing whole-object-by-value. The compiler will accept the latter; the wrappers may not.
3. **Keep object field types flat.** A registered Object whose fields are all primitives and `string` is universally safe. Adding a `seq[T]` field inside it makes the *enclosing* `seq[Outer]` impossible (footnote 2).
4. **For composite-heavy schemas, prefer CBOR mode.** `seq`-of-anything decodes naturally through `serde` (Rust) / `cbor2` (Python) / `jsoncons` (C++) without per-language CItem expansion. The CBOR build also covers a few cells (notably `array[N, Object]`) that the native build doesn't.

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

Field-by-field, every type is in a green row of all three sections (`seq[byte]`, string-aliased, `uint32`, `distinct int64`, `bool`).

| Position | Native | CBOR | Notes |
|---|---|---|---|
| Request **result** type — `Future[Result[WakuMessage, string]]` | ✅ | ✅ | All fields green; same shape as the validated `Tag`-style objects. |
| Event **payload** — `EventBroker(API): type WakuMessageReceived = object` with these fields | ✅ | ✅ | Same shape as `TagSeqEvent` / `PrimScalarEvent`, all green in the parity matrix. |
| Request **parameter** — `proc signature(msg: WakuMessage)` | ❌ | ✅ | Empirically: native C/C++ fail to compile (`unknown type name 'WakuMessage'`); native Python raises `ArgumentError`; native Rust emits `// TODO(rust-codegen)`. CBOR mode handles it via map-encoding (footnote 7). |
| Field of *another* registered Object | ❓ | ❓ | Inline-nested Object case is untested (footnote 1). |

**To use it as a request parameter today, flatten the struct:**

```nim
RequestBroker(API):
  type SendResult = object
    accepted*: bool

  proc signature(
    payload: seq[byte],
    contentTopic: string,
    meta: seq[byte],
    version: uint32,
    timestamp: Timestamp,
    ephemeral: bool,
    proof: seq[byte],
  ): Future[Result[SendResult, string]] {.async.}
```

Every individual parameter type is in the validated matrix. Callers can keep their own `WakuMessage` value and unpack at the call site:

```rust
// Rust (native or CBOR — same call shape)
let r = lib.send(
    msg.payload.clone(),
    msg.contentTopic.clone(),
    msg.meta.clone(),
    msg.version,
    msg.timestamp,
    msg.ephemeral,
    msg.proof.clone(),
);
```

```python
# Python — identical
r = lib.send(
    msg.payload, msg.content_topic, msg.meta,
    msg.version, msg.timestamp, msg.ephemeral, msg.proof,
)
```

**As an event payload, no transformation is needed:**

```nim
EventBroker(API):
  type WakuMessageReceived = object
    payload*: seq[byte]
    contentTopic*: ContentTopic
    meta*: seq[byte]
    version*: uint32
    timestamp*: Timestamp
    ephemeral*: bool
    proof*: seq[byte]
```

This generates `on_waku_message_received(closure)` with a closure signature that takes each field as an unpacked argument, in every wrapper × mode.

## Maintenance

When adding a probe to close one of the `❓` cells:

1. Add the type and a request/event using it to `test/typemappingtestlib/typemappingtestlib.nim`.
2. Add a corresponding assertion to the parity tests:
   - `test/typemappingtestlib/test_typemappingtestlib.cpp`
   - `test/typemappingtestlib/test_typemappingtestlib.py`
   - `test/typemappingtestlib/rust_test/src/main.rs`
3. Run all four `runTypeMapTestLib*` tasks (native + CBOR × Cpp/Py/Rust).
4. Update the relevant cell in this document with the result.

When a defect is found, document it in the footnotes with file/line evidence, **leave the failing probe out of the live test code** (it would block CI), and keep the matrix entry accurate.
