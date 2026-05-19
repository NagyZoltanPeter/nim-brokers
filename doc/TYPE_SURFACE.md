# Broker FFI API — Type Surface Mapping

How a Nim type used in a `RequestBroker(API)` / `EventBroker(API)` signature
manifests on each foreign wrapper's **public API surface** (what the
foreign developer actually writes).

Derived from the codegen mappers:
`nimTypeToCpp` / `primCppType`, `nimTypeToRust` / `rustPrimMap`,
`nimTypeToGo` / `goPrimMap`, `nimTypeToPyAnnotation` / `pyPrimMap`.

Two ABI modes exist:

- **Native** (`-d:BrokerFfiApiNative`) — a typed C ABI; the `.h` exposes the
  real struct/function shapes.
- **CBOR** (`-d:BrokerFfiApiCBOR`) — a fixed 11-function C ABI; **there is no
  typed C surface**, payloads ride as CBOR bytes. Only the C++/Rust/Go/Python
  wrappers carry the typed surface.

The C++/Rust/Go/Python columns are identical across both modes except where
a ⚠/† note says otherwise.

---

## 1. Scalar primitives

| Nim | C (native ABI) | C++ | Rust | Go | Python |
|-----|----------------|-----|------|-----|--------|
| `bool` | `bool` | `bool` | `bool` | `bool` | `bool` |
| `int8` | `int8_t` | `int8_t` | `i8` | `int8` | `int` |
| `int16` | `int16_t` | `int16_t` | `i16` | `int16` | `int` |
| `int32` | `int32_t` | `int32_t` | `i32` | `int32` | `int` |
| `int64` | `int64_t` | `int64_t` | `i64` | `int64` | `int` |
| `int` ⚠ | `int32_t` | `int32_t` (CBOR: `int64_t`) | `i32` | `int32` | `int` |
| `uint8` / `byte` | `uint8_t` | `uint8_t` | `u8` | `byte` | `int` |
| `uint16` | `uint16_t` | `uint16_t` | `u16` | `uint16` | `int` |
| `uint32` | `uint32_t` | `uint32_t` | `u32` | `uint32` | `int` |
| `uint64` | `uint64_t` | `uint64_t` | `u64` | `uint64` | `int` |
| `uint` ⚠ | `uint32_t` | `uint32_t` | `u32` | `uint32` | `int` |
| `float32` | `float` | `float` | `f32` | `float32` | `float` |
| `float64` / `float` | `double` | `double` | `f64` | `float64` | `float` |
| `string` | `char*` | `std::string` | `String` | `string` | `str` |
| `char` † | `char` | `char` | `String` | `string` | `str` |

⚠ **`int` / `uint` are width-ambiguous across modes** — native and CBOR-Rust/Go
treat them as 32-bit, but CBOR-C++ treats `int` as 64-bit. **Always use an
explicit width (`int32` / `int64`) in broker signatures.**

† `char` is only fully supported in CBOR mode.

---

## 2. Compound / combination types (result & request-param fields)

| Nim | C (native ABI) | C++ | Rust | Go | Python |
|-----|----------------|-----|------|-----|--------|
| `enum E` | `int32_t` (named `E` typedef) | `enum class E : int32_t` | `enum E` `#[repr(i32)]` | `type E int32` | `class E(IntEnum)` |
| `distinct D` (over prim `P`) | `P`'s C type | native: collapses to `P`; CBOR: `using D = P` | `pub type D = P` | `type D = P` | `D = <py P>` |
| `seq[T]` (primitive `T`) | `T* ptr` + `int32_t count` | `std::vector<T>` | `Vec<T>` | `[]T` | `list[int\|float]` |
| `seq[string]` | `char** ptr` + `int32_t count` | `std::vector<std::string>` | `Vec<String>` | `[]string` | `list[str]` |
| `seq[byte]` | `uint8_t* ptr` + `int32_t count` | `std::vector<uint8_t>` (CBOR: `jsoncons::byte_string`) | `Vec<u8>` (CBOR: `serde_bytes`) | `[]byte` | `list[int]` (CBOR: `bytes`) |
| `seq[object O]` | `OCItem* ptr` + `int32_t count` | `std::vector<O>` | `Vec<O>` | `[]O` | `list[O]` |
| `array[N, T]` | inline `T[N]` | native: `std::array<T,N>`; CBOR: `std::vector<T>` | `Vec<T>` | `[]T` | `list[...]` |
| `Option[T]` | `T value` + `bool <name>_has_value` | `std::optional<T>` | `Option<T>` | `*T` (nil = none) | `Optional[T]` |
| `object O` | `struct OCItem` (cstring fields) | `struct O` | `struct O` | `struct O` | `@dataclass O` |
| `tuple[...]` † | — | `struct` (named fields) | `struct` | `struct` | `@dataclass` |

† `tuple` and object-as-request-param are **CBOR-only**.

---

## 3. Top-level broker types (the type IN the `RequestBroker`/`EventBroker` block)

The broker's declared type is normally an inline `object`. It may also be a
bare primitive or `void`:

| Broker type | C++ | Rust | Go | Python |
|-------------|-----|------|-----|--------|
| `type X = object` (fields) | `struct X` | `struct X` | `struct X` | `@dataclass X` |
| `type X = int32` (primitive) | native: `struct X { int32_t value; }`; CBOR: `using X = int32_t` | native: `struct X { value: i32 }`; CBOR: `pub type X = i32` | native: `struct X { Value int32 }`; CBOR: `type X = int32` | native: dataclass `X(value)`; CBOR: `X = int` |
| **request** returns | `Result<X>` | `Result<X>` | `(X, error)` | `Result[X]` |
| **event** `X = int64` callback | `void(Lib&, int64_t)` | `Fn(i64)` | `func(int64)` | `Callable[[Lib, int], None]` |
| `type X = void` (payload-less) | native: `Result<X>` (empty struct); CBOR: `Result<void>` | `Result<X>` (empty struct) | `(X, error)` (empty struct) | `Result[X]` (empty dataclass) |
| **event** `X = void` callback | `void(Lib&)` | `Fn()` | `func()` | `Callable[[Lib], None]` |

A `void` broker type is lowered to a *unique empty object* (a unit type) so
each broker keeps a distinct identity for typedesc dispatch. A void request
carries only the ok/err signal — `isOk()` is all the caller inspects; the
CBOR C++ wrapper surfaces it as `Result<void>`, the other wrappers as a
`Result<>` of the zero-field type. A void event delivers a payload-less
callback. Inside the single-thread broker the listener/`emit` are argless;
the MT broker keeps the empty-object form internally.

For a **primitive request** the native wrapper boxes the scalar in a
one-field struct (`.value`); the CBOR wrapper exposes the bare type alias.
For a **primitive event** every wrapper delivers the bare scalar as the sole
callback argument.

---

## 4. Event callbacks — note on parameter shapes

Event payload fields are delivered **unpacked** as positional callback args.
Non-POD fields use a borrowed view rather than the owning result-side type:

| Nim field | C++ callback param | Rust | Go | Python |
|-----------|--------------------|------|-----|--------|
| `string` | `std::string_view` | `String` | `string` | `str` |
| `seq[T]` | `std::span<const T>` | `Vec<T>` | `[]T` | `list[...]` |
| primitive | by value | by value | by value | by value |

---

## 5. Ownership (native mode)

Every heap-allocated result field (`char*`, `seq` pointer arrays, `CItem`
arrays) is allocated on the shared heap by the generated `encode*` proc and
released by the matching `<lib>_free_<name>_result(...)`. The C++/Python/
Rust/Go wrappers call that free function automatically (RAII / `finally` /
`Drop` / finalizer). In CBOR mode all payload memory is CBOR scratch buffers
owned by the wrapper.
