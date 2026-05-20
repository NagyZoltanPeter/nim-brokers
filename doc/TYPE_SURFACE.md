# Broker FFI API — Type Surface Mapping

How a Nim type used in a `RequestBroker(API)` / `EventBroker(API)` signature
manifests on each foreign wrapper's **public API surface** (what the
foreign developer actually writes).

Derived from the codegen mappers in
`brokers/internal/api_codegen_cbor_{hpp,rust,go,py}.nim`.

## ABI mode

CBOR (`-d:BrokerFfiApiCBOR`, also the default whenever `-d:BrokerFfiApi`
is set) is the only FFI mode. It exposes a fixed 11-function C ABI;
payloads ride as CBOR bytes. Only the C++ / Rust / Go / Python wrappers
carry the typed surface — pure-C consumers currently see only the raw
ABI (see `doc/CBOR_Refactoring.md` §10 for the deferred typed-C work).

The native per-type C codegen was retired — see `doc/CBOR_Refactoring.md`.
Trying to compile with `-d:BrokerFfiApiNative` is a hard error pointing
back to that document.

---

## 1. Scalar primitives

| Nim | C++ | Rust | Go | Python |
|-----|-----|------|-----|--------|
| `bool` | `bool` | `bool` | `bool` | `bool` |
| `int8` | `int8_t` | `i8` | `int8` | `int` |
| `int16` | `int16_t` | `i16` | `int16` | `int` |
| `int32` | `int32_t` | `i32` | `int32` | `int` |
| `int64` | `int64_t` | `i64` | `int64` | `int` |
| `int` ⚠ | `int64_t` | `i32` | `int32` | `int` |
| `uint8` / `byte` | `uint8_t` | `u8` | `byte` | `int` |
| `uint16` | `uint16_t` | `u16` | `uint16` | `int` |
| `uint32` | `uint32_t` | `u32` | `uint32` | `int` |
| `uint64` | `uint64_t` | `u64` | `uint64` | `int` |
| `uint` ⚠ | `uint32_t` | `u32` | `uint32` | `int` |
| `float32` | `float` | `f32` | `float32` | `float` |
| `float64` / `float` | `double` | `f64` | `float64` | `float` |
| `string` | `std::string` | `String` | `string` | `str` |
| `char` | `char` | `String` | `string` | `str` |

⚠ **`int` / `uint` are width-ambiguous across wrappers** (C++ treats `int`
as 64-bit, Rust/Go as 32-bit). **Always use an explicit width
(`int32` / `int64`) in broker signatures.**

---

## 2. Compound / combination types (result & request-param fields)

| Nim | C++ | Rust | Go | Python |
|-----|-----|------|-----|--------|
| `enum E` | `enum class E : int32_t` | `enum E` `#[repr(i32)]` | `type E int32` | `class E(IntEnum)` |
| `distinct D` (over prim `P`) | `using D = P` | `pub type D = P` | `type D = P` | `D = <py P>` |
| `seq[T]` (primitive `T`) | `std::vector<T>` | `Vec<T>` | `[]T` | `list[int\|float]` |
| `seq[string]` | `std::vector<std::string>` | `Vec<String>` | `[]string` | `list[str]` |
| `seq[byte]` | `jsoncons::byte_string` | `serde_bytes::ByteBuf` | `[]byte` | `bytes` |
| `seq[object O]` | `std::vector<O>` | `Vec<O>` | `[]O` | `list[O]` |
| `array[N, T]` | `std::vector<T>` | `Vec<T>` | `[]T` | `list[...]` |
| `Option[T]` | `std::optional<T>` | `Option<T>` | `*T` (nil = none) | `Optional[T]` |
| `object O` | `struct O` | `struct O` | `struct O` | `@dataclass O` |
| `tuple[...]` | `struct` (named fields) | `struct` | `struct` | `@dataclass` |

---

## 3. Top-level broker types (the type IN the `RequestBroker`/`EventBroker` block)

The broker's declared type is normally an inline `object`. It may also be a
bare primitive or `void`:

| Broker type | C++ | Rust | Go | Python |
|-------------|-----|------|-----|--------|
| `type X = object` (fields) | `struct X` | `struct X` | `struct X` | `@dataclass X` |
| `type X = int32` (primitive) | `using X = int32_t` | `pub type X = i32` | `type X = int32` | `X = int` |
| **request** returns | `Result<X>` | `Result<X>` | `(X, error)` | `Result[X]` |
| **event** `X = int64` callback | `Fn(i64)` | `Fn(i64)` | `func(int64)` | `Callable[[Lib, int], None]` |
| `type X = void` (payload-less) | `Result<void>` | `Result<X>` (empty struct) | `(X, error)` (empty struct) | `Result[X]` (empty dataclass) |
| **event** `X = void` callback | `void(Lib&)` | `Fn()` | `func()` | `Callable[[Lib], None]` |

A `void` broker type is lowered to a *unique empty object* (a unit type) so
each broker keeps a distinct identity for typedesc dispatch. A void request
carries only the ok/err signal — `isOk()` is all the caller inspects; the
C++ wrapper surfaces it as `Result<void>`, the other wrappers as a
`Result<>` of the zero-field type. A void event delivers a payload-less
callback. Inside the single-thread broker the listener/`emit` are argless;
the MT broker keeps the empty-object form internally.

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

## 5. Ownership

All payload memory is CBOR scratch buffers owned by the wrapper. Each
`<lib>_call` round-trip allocates a request buffer (Nim shared heap, freed
by the processing thread after decode) and a response buffer (Nim shared
heap, freed via `<lib>_freeBuffer` from the wrapper's RAII / Drop /
finalizer / `finally` path). The C ABI never hands raw heap pointers
through typed signatures — every cross-boundary lifetime is CBOR-buffer
bounded.
