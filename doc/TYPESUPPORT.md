# Broker FFI API — Type-support matrix

Authoritative reference for which Nim type patterns are supported across
each foreign-language wrapper (C++ / Python / Rust / Go). Cells are
evidence-backed: ✅ entries are validated by the parity test suite
(`runTypeMapTestLibCborCpp`, `runTypeMapTestLibCborPy`,
`runTypeMapTestLibCborRust`, `runTypeMapTestLibCborGo`); ❌ entries are
confirmed broken by direct probe; ❓ entries are untested.

**Pure C is not in the matrix.** The typed-C wrapper is deferred — see
`doc/CBOR_Refactoring.md` §10. Pure-C consumers currently see only the
raw 11-function CBOR ABI and must hand-encode payloads against it.

## ABI mode

CBOR (`-d:BrokerFfiApiCBOR`, also the default whenever `-d:BrokerFfiApi`
is set) is the only FFI mode. The native per-type C codegen was retired
— see `doc/CBOR_Refactoring.md`. Trying to compile with
`-d:BrokerFfiApiNative` is a hard compile error.

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
| Object (all primitive/string fields) — embedded as an *inline field* of another object | ❓ ¹ | ❓ ¹ | ❓ ¹ | ❓ ¹ |
| `seq[byte]` | ✅ | ✅ | ✅ | ✅ |
| `seq[primitive]` (e.g. `seq[int64]`) | ✅ | ✅ | ✅ | ✅ |
| `seq[string]` | ✅ | ✅ | ✅ | ✅ |
| `seq[Object]` (Object has prim/string fields only) | ✅ | ✅ | ✅ | ✅ |
| `seq[Object<seq>]` (the inner object contains its own `seq[T]`) | ❌ ² | ❌ ² | ❌ ² | ❌ ² |
| `array[N, primitive]` | ✅ | ✅ | ✅ | ✅ |
| `array[N, string]` | ❌ ³ | ❌ ³ | ❌ ³ | ❌ ³ |
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
| `seq[Object<seq>]` | ❌ ² | ❌ ² | ❌ ² | ❌ ² |
| `array[N, primitive]` | ❓ ⁴ | ❓ ⁴ | ❓ ⁴ | ❓ ⁴ |
| `array[N, string]` | ❌ ³ | ❌ ³ | ❌ ³ | ❌ ³ |
| `array[N, Object]` | ❓ ⁴ | ❓ ⁴ | ❓ ⁴ | ❓ ⁴ |
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
| `seq[Object<seq>]` | ❌ ² | ❌ ² | ❌ ² | ❌ ² |
| `array[N, primitive]` | ✅ | ✅ | ✅ | ✅ |
| `array[N, string]` | ❓ ⁵ | ❓ ⁵ | ❓ ⁵ | ❓ ⁵ |
| `array[N, Object]` | ❓ ⁵ | ❓ ⁵ | ❓ ⁵ | ❓ ⁵ |

## Footnotes

1. **Object as inline field** — e.g. `type Outer = object; inner: Inner`
   with both registered. CBOR map-encoding nests naturally, and the
   schema registry walks nested object fields, so this almost certainly
   works on every wrapper, but no test exercises it. Treat as untested
   until a probe is added.

2. **`seq[Object<seq>]` — inner object contains a composite field.**
   The codegen restricts `seq[T]` element objects to those with
   primitive / string / Option fields only. An inner object that itself
   contains a `seq[T]` field cannot register as an element type and the
   outer composite never reaches codegen. Affects every wrapper equally.

3. **`array[N, string]`** — the macro rejects `array[N, string]` because
   the wrapper-side codegen does not currently emit a fixed-size string
   array translation. Use `seq[string]` instead.

4. **`array[N, T]` as request param** — every test exercises
   `array[N, T]` only as a *result* field, never as a parameter. No
   end-to-end coverage; treat as suspect until probed.

5. **`array[N, string]` / `array[N, Object]` in events** — no empirical
   data. The event codegen path is independent from the request path,
   so behaviour may differ; treat as untested until probed.

## Recommended idioms

To stay safely inside the green cells:

1. **Use `seq[T]` over `array[N, T]` when the element is `string`.**
   Fixed-size arrays of strings are rejected (footnote 3). Fixed-size
   arrays of primitives and (as a result field) Objects are safe.
2. **Keep object field types flat or `seq[primitive]`.** A registered
   Object whose fields are all primitives, strings, or `seq[primitive]`
   is universally safe. Adding a `seq[CompositeT]` field inside an
   element-type object makes the *enclosing* `seq[Outer]` impossible
   (footnote 2).

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
| Field of *another* registered Object | ❓ | Inline-nested Object case is untested (footnote 1). |

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
