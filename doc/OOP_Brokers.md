# OOP Brokers — Interface / Implementation Model

`BrokerInterface` and `BrokerImplement` are **syntactic sugar over the same
`EventBroker` and `RequestBroker` macros** that power the flat broker API.
They work on every broker layer:

| Interface form | What the inner brokers become |
|---------------|-------------------------------|
| `BrokerInterface(IFace):` | Re-emitted **verbatim** — `EventBroker:` stays `EventBroker:`, `RequestBroker(sync):` stays `RequestBroker(sync):`, etc. |
| `BrokerInterface(API, IFace):` | `(API)` is **auto-propagated** to every inner broker — `EventBroker:` becomes `EventBroker(API):`, `RequestBroker:` becomes `RequestBroker(API):` |

The only automatic promotion is `(API)`. For multi-thread brokers, write
`EventBroker(mt):` / `RequestBroker(mt):` explicitly inside the interface
body — the macro passes them through as-is. The underlying broker machinery
is identical in all cases — the OOP layer adds structure on top without
changing runtime behavior.

---

## Why use OOP brokers?

### Separation of concerns — interface vs implementation

The flat broker macros couple the *definition* of a communication contract
with the *global* registration of handlers. In a larger system you want:

- **Interface modules** that declare *what* a component can do — events it
  emits, requests it answers — without knowing *how*.
- **Implementation modules** that provide the behavior, potentially swapped at
  runtime or between test/production builds.

`BrokerInterface` is the contract; `BrokerImplement` is the fulfillment.
Consumer code depends only on the interface module — it never imports the
implementation.

### Dependency injection / Inversion of Control (DI/IoC)

Each `BrokerInterface` automatically generates a **factory broker**:

- `IFace.provideFactory(constructor)` — registers a constructor (last wins).
- `IFace.create()` / `IFace.create(config)` — returns an instance through the
  base type, resolved at runtime.

This is classic DI: the consumer asks for `IGreeter.create()` without knowing
whether it gets `GreeterImpl`, `MockGreeter`, or a proxy. The factory can
close over external configuration or accept a typed config argument with a
compile-time type guard.

```nim
# -- registration (implementation module) --
IGreeter.provideFactory(
  proc(cfg: string): Result[IGreeter, string] =
    ok(GreeterImpl.create(prefix = cfg))
)

# -- consumption (consumer module, knows only IGreeter) --
let svc = IGreeter.create("production:").value
let res = waitFor svc.greet("alice")   # virtual dispatch → GreeterImpl.greet
```

### Per-instance isolation

Every instance created via `create()` or `createUnderContext()` gets its own
`BrokerContext`. Providers and event listeners registered by one instance are
completely isolated from another — two `GreeterImpl` instances serve
independent request streams, emit independent events, and can be closed
independently.

### Deterministic lifecycle

`BrokerImplement` generates a `close()` proc that:

1. Clears all request providers registered by this instance.
2. Drops all event listeners registered through the instance's event facade.
3. Marks the instance as closed (idempotent — safe to call twice).

This breaks the `instance -> provider closure -> instance` reference cycle that
would otherwise leak under `--mm:refc`. Under `--mm:orc` the cycle collector
would eventually collect it, but explicit `close()` gives deterministic cleanup
regardless of GC strategy.

---

## Core concepts

### BrokerInterface — the contract

`BrokerInterface` declares an abstract facade over a group of brokers. It
generates:

- A **`ref object of RootObj`** base type with a hidden `brokerCtx` field.
- The underlying `EventBroker` / `RequestBroker` definitions (re-emitted
  verbatim from the block body).
- One **public request `proc`** per request verb that *tunnels* through the
  broker: `proc greet(self, …) = Greet.request(self.brokerCtx, …)`. It is a
  plain proc, **not** a `{.base.}` virtual method — routing is by ctx, so the
  call always goes through the broker dispatch path (see *Method calls tunnel
  through the broker* below).
- An **instance-scoped event facade** (`self.emit`, `self.listen`,
  `self.dropListener`) that automatically injects `self.brokerCtx`.
- A **factory broker** for dependency injection (`provideFactory` / `create`).

```nim
import brokers/broker_interface

BrokerInterface(IGreeter):
  EventBroker:
    type Greeted = object
      who: string

  RequestBroker:
    proc greet(name: string): Future[Result[string, string]] {.async.}

  RequestBroker:
    proc version(): Future[Result[string, string]] {.async.}
```

After this block, `IGreeter` is a `ref object` type, `Greeted` is an event
broker, `Greet` and `Version` are request brokers, and `IGreeter` has public
tunneling procs `greet` and `version` that forward to `Greet.request` /
`Version.request` (keyed by `self.brokerCtx`).

#### Request syntax — proc sugar

Inside a `BrokerInterface`, requests use a **proc-sugar** form: a lowercase
verb proc whose name becomes the interface's public request proc. The macro
derives the broker type name from the proc name (e.g. `greet` -> `Greet`
broker type). This is more concise than the flat `type + proc signature*` form
and maps directly to the `<Broker>.request(...)` call the proc tunnels to.

### BrokerImplement — the fulfillment

`BrokerImplement` attaches behavior to a concrete `ref object of IFace` type.
The user authors a natural `proc new` constructor that builds and returns a
**bare** instance; the macro generates the decorators that bind a context and
wire providers. It generates:

- **`Impl.create(args...)`** — allocates a fresh `BrokerContext`, calls the
  user `new`, runs the optional `init(self)` hook, and wires per-instance
  provider closures. This is the normal in-process constructor.
- **`Impl.createUnderContext(ctx, args...)`** — same, but **adopts** an
  externally-provided `BrokerContext` instead of allocating one. Used by the
  FFI layer to wire an implementation onto the context created by
  `<lib>_createContext()`, and by facades that hand sub-instances a child ctx.
- **`close(self)`** — clears providers + drops listeners, breaking the
  closure cycle.

The body of `BrokerImplement` accepts:

- **`proc new(T: typedesc[Impl], args...): Impl`** *(optional)* — builds and
  returns a bare instance (no ctx, no providers). Omit it and a zero-arg
  default (`Impl()`) is synthesized. Note: a bare instance is unwired — call
  `create` / `createUnderContext` to get a working one.
- **`proc init(self: Impl)`** *(optional)* — a post-context hook that runs
  *after* `self.brokerCtx` is bound and *before* providers are wired. Use it
  for ctor logic that derives per-instance state from `self.brokerCtx` (the
  bare `new` cannot see the ctx, since it is assigned afterwards).
- **`method <verb>(self: Impl, args...): …`** — the raw body for each request
  verb. It is emitted as a private `<verb>Impl` proc and invoked **only** by
  the provider closure; the public entry point is the interface's tunneling
  proc.

```nim
type GreeterImpl = ref object of IGreeter
  prefix: string

BrokerImplement GreeterImpl of IGreeter:
  proc new(T: typedesc[GreeterImpl], prefix: string): GreeterImpl =
    GreeterImpl(prefix: prefix)

  method greet(
      self: GreeterImpl, name: string
  ): Future[Result[string, string]] {.async.} =
    ok(self.prefix & name)

  method version(
      self: GreeterImpl
  ): Future[Result[string, string]] {.async.} =
    ok("v2")

let g = GreeterImpl.create(prefix = "hello ")   # wired, fresh ctx
```

Every request verb from the interface **must** have a `method` body — the
macro verifies this at compile time.

#### Method calls tunnel through the broker

A call to `g.greet("bob")` — or via a base-typed ref, `IGreeter(g).greet("bob")`
— does **not** run the method body inline. It invokes the interface's public
proc, which calls `Greet.request(self.brokerCtx, "bob")`; the broker then
dispatches to the registered provider closure, which runs the raw `greetImpl`
body. Consequences:

- **Mocks intercept direct calls.** Swapping `Greet`'s provider for a ctx is
  honored by `g.greet(...)`, not just by `Greet.request(...)`.
- **MT cross-thread is safe.** With the `(API)`/multi-thread lane, calling a
  method from a thread other than the instance's owner tunnels via the channel
  to the owning thread; the body never runs on the wrong thread. Under
  `--mm:refc` the caller only borrows `self` and reads the value field
  `brokerCtx` (no refcount mutation across heaps).

#### Inner broker modes — `mt` / `sync` (and how to get cross-thread without FFI)

`BrokerInterface` does **not** force a single mode on its brokers. How the inner
brokers are emitted depends on the interface form:

| Interface form | Inner broker | Resulting lane |
|----------------|--------------|----------------|
| `BrokerInterface(API, IFace):` | must be **plain** `EventBroker:` / `RequestBroker:` (an explicit mode marker is a compile error) | `(API)` is auto-applied to every inner broker — the FFI/MT lane. |
| `BrokerInterface(IFace):` | `RequestBroker(mt):` / `EventBroker(mt):` | re-emitted verbatim → **multi-thread** broker with cross-thread channel tunneling, **no FFI machinery**. |
| `BrokerInterface(IFace):` | `RequestBroker(sync):` | re-emitted verbatim → **sync** broker; the interface proc tunnels to the sync `request`. |
| `BrokerInterface(IFace):` | plain `RequestBroker:` | single-thread, thread-local broker — **same-thread only**. |

So there are **two** ways to get cross-thread method tunneling:

1. `BrokerInterface(API, IFace):` — the FFI lane (also exposes a C ABI).
2. `BrokerInterface(IFace):` with `RequestBroker(mt):` inner brokers — pure
   in-process multi-thread, no FFI. An instance created on the owning thread can
   have its methods invoked from another thread; the call tunnels to the owner
   via the channel, exactly as in the `(API)` case.

```nim
BrokerInterface(ISvc):              # plain interface (no API)
  RequestBroker(mt):                # ← MT inner broker: cross-thread tunneling
    proc work(n: int): Future[Result[int, string]] {.async.}

  RequestBroker(sync):              # ← sync inner broker is fine too
    proc tag(): Result[string, string]
```

A plain interface with plain inner brokers stays single-thread (thread-local);
add `(mt)` per broker to opt into cross-thread dispatch without the FFI layer.

---

## Usage patterns — the persistence example

The real power of `BrokerInterface` / `BrokerImplement` is not basic
OOP-style `new()` + method dispatch — plain Nim inheritance already gives you
that. The power is **defining an abstract interface in one module, implementing
it in completely separate modules, swapping implementations at runtime, and
having the consumer never import or know about any concrete type.**

The **persistence example** (`examples/persistence/`) demonstrates this
cleanly. It defines a two-level interface hierarchy — a main facade and a
sub-interface for storage backends — with two independently swappable
backend implementations that coexist under one library.

### Step 1 — Define the contract (interface module)

The interface module declares *what* the system can do. No behavior, no
imports of implementation modules, no state:

```nim
# PersistenceAPI.nim — the contract (ONLY module consumers import)

type BackendKind* = enum
  bkMemory = 0
  bkFile = 1

# Sub-interface: a storage backend
BrokerInterface(API, IBackend):
  EventBroker:
    type ReadCompleted = object
      key*: string
      value*: string
      found*: bool

  RequestBroker:
    proc store(key: string, value: string): Future[Result[bool, string]] {.async.}

  RequestBroker:
    proc read(key: string): Future[Result[bool, string]] {.async.}

# Main interface: the persistence facade
BrokerInterface(API, IPersistence):
  EventBroker:
    type BackendCreated = object
      handle*: uint32
      kind*: int32

  RequestBroker:
    proc makeBackend(kind: int32): Future[Result[IBackend, string]] {.async.}

  RequestBroker:
    type ListBackends* = object
      backends*: seq[BackendInfo]
    proc listBackends(): Future[Result[ListBackends, string]] {.async.}

  RequestBroker:
    proc terminateBackend(handle: uint32): Future[Result[bool, string]] {.async.}
```

After this, `IBackend` and `IPersistence` are abstract base types whose request
verbs are public tunneling procs. **No concrete implementation exists here.**
Any module that imports `PersistenceAPI` can call `store` / `read` /
`makeBackend` etc. through the interface — it never needs to know which
implementation is behind it.

### Step 2 — Implement (separate modules, swappable)

Each implementation lives in its own module and imports only the interface:

```nim
# MemoryBackend.nim — an in-memory IBackend implementation
import ./PersistenceAPI

type MemoryBackendImpl* = ref object of IBackend
  data: Table[string, string]

BrokerImplement MemoryBackendImpl of IBackend:
  proc new(T: typedesc[MemoryBackendImpl]): MemoryBackendImpl =
    MemoryBackendImpl(data: initTable[string, string]())

  method store(self: MemoryBackendImpl, key, value: string
  ): Future[Result[bool, string]] {.async.} =
    self.data[key] = value
    ok(true)

  method read(self: MemoryBackendImpl, key: string
  ): Future[Result[bool, string]] {.async.} =
    let found = self.data.hasKey(key)
    asyncSpawn self.emitReadResult(key, self.data.getOrDefault(key), found)
    ok(true)  # ack immediately; result delivered via ReadCompleted event
```

```nim
# FileBackend.nim — a file-backed IBackend implementation
import ./PersistenceAPI

type FileBackendImpl* = ref object of IBackend
  dir: string

BrokerImplement FileBackendImpl of IBackend:
  # `init(self)` runs after brokerCtx is bound, so the dir can derive from it.
  # (A bare `proc new` cannot — the ctx is assigned by createUnderContext after
  # `new` returns.)
  proc init(self: FileBackendImpl) =
    self.dir = "persist_" & $uint32(self.brokerCtx)

  method store(self: FileBackendImpl, key, value: string
  ): Future[Result[bool, string]] {.async.} =
    writeFile(self.dir / key, value)
    ok(true)

  method read(self: FileBackendImpl, key: string
  ): Future[Result[bool, string]] {.async.} =
    let found = fileExists(self.dir / key)
    asyncSpawn self.emitReadResult(key, if found: readFile(self.dir / key) else: "", found)
    ok(true)
```

Both modules fulfill the same `IBackend` contract. They share nothing — no
common base logic, no import of each other. A third implementation (e.g.
`SqliteBackendImpl`) could be added without touching the existing two or the
consumer.

### Step 3 — The facade picks implementations at runtime

The facade implementation imports both backends and creates the right one
based on a runtime parameter:

```nim
# PersistenceFacade.nim — the IPersistence facade
import ./PersistenceAPI, ./MemoryBackend, ./FileBackend

type PersistenceImpl* = ref object of IPersistence
  backends: seq[BackendEntry]

BrokerImplement PersistenceImpl of IPersistence:
  method makeBackend(self: PersistenceImpl, kind: int32
  ): Future[Result[IBackend, string]] {.async.} =
    let subCtx = newInstanceCtx(self.brokerCtx)
    var be: IBackend
    if kind == int32(bkFile):
      be = FileBackendImpl.createUnderContext(subCtx)
    else:
      be = MemoryBackendImpl.createUnderContext(subCtx)
    # ...track, emit BackendCreated...
    ok(be)

  method terminateBackend(self: PersistenceImpl, handle: uint32
  ): Future[Result[bool, string]] {.async.} =
    # targeted teardown of a single backend, others unaffected
    # ...find by handle, call close(), mark dead...
```

### What this gives you

1. **The consumer (foreign or Nim) never imports an implementation module.**
   It depends on `PersistenceAPI` alone. It calls `makeBackend(bkMemory)` or
   `makeBackend(bkFile)` and gets back an `IBackend` — same type, same
   methods, different behavior underneath.

2. **Implementations are runtime-swappable.** The facade picks the concrete
   type from a parameter. In tests you can mock a backend's provider per ctx
   (see *Testing — mocking providers* below); in production a real one — the
   consumer code is identical.

3. **Each sub-instance is fully isolated.** Every backend created by
   `createUnderContext(newInstanceCtx(...))` gets its own `BrokerContext`, its own
   providers, its own event listeners. `terminateBackend` closes one backend
   without disturbing others.

4. **Events are instance-scoped.** `self.emit(ReadCompleted, ...)` fires only
   to listeners registered on *this* backend's context. Two backends can emit
   the same event type concurrently without interference.

5. **FFI gets the same structure for free.** Over the C ABI, `makeBackend`
   returns the sub-instance's `BrokerContext` as a `uint32`. The generated
   C++ / Python / Rust / Go wrapper turns it into a typed `Backend` object
   with `store()` / `read()` / `on_read_completed()` methods. The consumer
   creates backends, uses them independently, and releases them — all through
   the typed wrapper surface.

### Factory / DI — the `provideFactory` / `create` path

For simpler single-interface scenarios where you don't need a facade, the
built-in factory broker offers direct DI:

```nim
# -- registration (in the implementation module) --
IGreeter.provideFactory(
  proc(): Result[IGreeter, string] =
    ok(GreeterImpl.create(prefix = "default:"))
)

# -- consumption (in the consumer module — knows only IGreeter) --
let svc = IGreeter.create()    # returns the impl behind the interface type
assert (waitFor svc.value.greet("x")).value == "default:x"
```

The factory can also accept a typed configuration argument:

```nim
IGreeter.provideFactory(
  proc(cfg: string): Result[IGreeter, string] =
    ok(GreeterImpl.create(prefix = cfg))
)

let svc = IGreeter.create("custom:")
# Wrong config type is caught at runtime:
assert IGreeter.create(123).isErr()
```

### Testing — mocking providers

Because every method call tunnels through `<Broker>.request(self.brokerCtx, …)`,
a test can replace the provider for one broker on one context and the swap is
honored by **direct method calls** (`g.greet(...)`), base-typed calls
(`IGreeter(g).greet(...)`), and `Greet.request(...)` alike — no need to touch
the implementation. The RequestBroker exposes:

- **`Greet.getCurrentProvider(ctx)`** → `Option[<with-arg provider>]` — capture
  the installed provider. For a zero-arg verb use
  **`Version.getCurrentProviderNoArgs(ctx)`** (distinct name: a return-type-only
  overload is illegal, and both slots may coexist on one broker).
- **`Greet.replaceProvider(ctx, handler)`** — overwrite without `setProvider`'s
  "already set" error (replace-or-insert).
- **`Greet.withMockProvider(ctx, mock): body`** — scoped, exception-safe: install
  `mock`, run `body`, then restore the captured provider (or clear it if none).

```nim
let g = GreeterImpl.create(prefix = "real:")

Greet.withMockProvider(
  g.brokerCtx,
  proc(name: string): Future[Result[string, string]] {.async.} =
    ok("MOCK<" & name & ">"),
):
  check (waitFor g.greet("bob")).value == "MOCK<bob>"   # direct call hits mock
check (waitFor g.greet("bob")).value == "real:bob"      # restored after block
```

> **Multi-thread / `(API)` note.** The introspection API reads the provider's
> per-thread storage, so `getCurrentProvider` / `replaceProvider` /
> `withMockProvider` must be called on the provider's **owning thread** (the one
> that ran `setProvider` / `createUnderContext`). Cross-thread introspection is
> not supported.

### Context split — `classCtx` / `instanceCtx`

The `BrokerContext` `uint32` encodes two halves: bits `[15:0]` are `classCtx`
(identifies the interface / library), bits `[31:16]` are `instanceCtx`
(identifies the instance). `createUnderContext(newInstanceCtx(parent.brokerCtx))`
shares the parent's `classCtx` with a fresh `instanceCtx`.

This split lets the FFI dispatch layer recover the owning library context by
masking off the instance half — so sub-instance calls route through the same
processing thread as the main class.

---

## FFI integration — `BrokerInterface(API)`

When an interface is declared with the `(API)` marker, the OOP model
integrates seamlessly with the Broker FFI API layer:

```nim
BrokerInterface(API, IHier):
  EventBroker:
    type Tick = object
      n: int32

  RequestBroker:
    proc getValue(): Future[Result[int32, string]] {.async.}

  RequestBroker:
    proc makeWidget(size: int32): Future[Result[IWidget, string]] {.async.}

  RequestBroker:
    proc echoLen(s: string): Future[Result[int32, string]] {.async.}
```

The `(API)` marker **propagates** to every `EventBroker` / `RequestBroker`
inside the block — they become `EventBroker(API)` / `RequestBroker(API)`
automatically. No per-broker annotation needed.

### Connecting to `registerBrokerLibrary`

The FFI lifecycle hook `setupProviders(ctx)` uses `createUnderContext` to adopt
the library-allocated context:

```nim
type HierImpl = ref object of IHier
  value: int32

BrokerImplement HierImpl of IHier:
  proc new(T: typedesc[HierImpl]): HierImpl =
    HierImpl(value: 7)
  method getValue(self: HierImpl): Future[Result[int32, string]] {.async.} =
    ok(self.value)
  method makeWidget(self: HierImpl, size: int32): Future[Result[IWidget, string]] {.async.} =
    let w = WidgetImpl.createUnderContext(newInstanceCtx(self.brokerCtx), size)
    ok(IWidget(w))
  # ... other method bodies ...

proc setupProviders(ctx: BrokerContext): Result[void, string] =
  discard HierImpl.createUnderContext(ctx)
  ok()

registerBrokerLibrary:
  name: "hierlib"
  version: "0.1.0"
  mainClass: IHier
  initializeRequest: InitializeRequest
  shutdownRequest: ShutdownRequest
```

The `mainClass` field tells the library generator which interface owns the
library lifecycle (`createContext` / `shutdown`).

### Generated wrapper class layout

The codegen produces **one main wrapper class** from the `mainClass` interface
and **one sub-wrapper class per sub-interface**. The class layout is consistent
across all generated languages — same methods, same ownership semantics,
idiomatic naming per language convention.

#### Main class — the library facade

The main `BrokerInterface(API)` becomes a single wrapper class that owns the
library context and exposes all its requests as typed methods and all its
events as subscribe/unsubscribe pairs:

| Generated artifact | C++ | Python | Rust | Go |
|--------------------|-----|--------|------|----|
| Class / struct | `class Hierlib` | `class Hierlib` | `struct Hierlib` | `type Hierlib struct` |
| Constructor | `Hierlib()` | `Hierlib()` | `Hierlib::new()` | `hierlib.New()` |
| Lifecycle | `createContext()` / `shutdown()` / `~Hierlib()` | `create_context()` / `shutdown()` / `close()` / context-mgr | `create_context()` / `shutdown()` / `Drop` | `CreateContext()` / `Close()` / `runtime.SetFinalizer` |
| Request methods | `getValue() -> Result<GetValue>` | `get_value() -> Result` | `get_value() -> HierlibResult<GetValue>` | `GetValue() -> (int32, error)` |
| Event subscribe | `onTick(callback) -> handle` | `on_tick(callback) -> handle` | `on_tick(closure) -> handle` | `OnTick(func) -> handle` |
| Event unsubscribe | `offTick(handle)` | `off_tick(handle)` | `off_tick(handle)` | `OffTick(handle)` |
| Static version | `Hierlib::version()` | `Hierlib.version()` | `Hierlib::version()` | `hierlib.Version()` |
| Copyable | No (deleted) | No (single owner) | No (no Clone) | No (pointer semantics) |

The main class is **non-copyable / non-movable** (C++ deletes copy/move
constructors; Rust has no `Clone`; Go uses pointer receiver + finalizer;
Python uses `__del__`/`close()`). If you need it in a container, use
`std::unique_ptr<Hierlib>` (C++) or equivalent.

Event callbacks receive the owner as the first argument (C++: `Hierlib&`,
Python: the `Hierlib` instance) so handlers can call back into the library.
Exceptions in callbacks are swallowed before crossing the C ABI boundary.

#### Sub-interface classes — created by the main class

When a request returns a sub-interface type (e.g. `makeWidget` returns
`IWidget`), the generated wrapper **creates a typed sub-class** for the
consumer to use:

| Generated artifact | C++ | Python | Rust | Go |
|--------------------|-----|--------|------|----|
| Class / struct | `class Widget` | `class Widget` | `struct Widget` | `type Widget struct` |
| Created by | `lib.makeWidget(5) -> Result<Widget>` | `lib.make_widget(5).value` | `lib.make_widget(5)` | `lib.MakeWidget(5)` |
| Own methods | `area()`, `scale(factor)` | `area()`, `scale(factor)` | `area()`, `scale(factor)` | `Area()`, `Scale(factor)` |
| Lifetime | RAII destructor / move-only | `close()` / context-mgr | `Drop` | `Close()` / `SetFinalizer` |
| Context | Own `instanceCtx` (shares parent's `classCtx`) | Same | Same | Same |

Over the CBOR wire, the sub-instance is serialized as its `BrokerContext`
(`uint32`). The wrapper reconstructs a typed object from it. The sub-object's
calls route through the same C ABI (`<lib>_call`) and the same processing
thread as the main class — the `classCtx` mask in the `BrokerContext` ensures
correct dispatch.

#### Example: consumer code across languages

**C++:**
```cpp
Hierlib lib;
lib.createContext();
assert(lib.getValue().value() == 7);

auto wr = lib.makeWidget(5);
Widget widget = std::move(wr.take());
assert(widget.area().value() == 25);
assert(widget.scale(3).value() == 15);
// widget destroyed by RAII at scope exit → calls hierlib_releaseInstance
```

**Python:**
```python
lib = hierlib.Hierlib()
lib.create_context()
assert lib.get_value().value == 7

widget = lib.make_widget(5).value
assert widget.area().value == 25
assert widget.scale(3).value == 15
widget.close()
```

**Rust:**
```rust
let mut lib = Hierlib::new();
lib.create_context()?;
assert_eq!(*lib.get_value().value().unwrap(), 7);

let mut widget = lib.make_widget(5).into_result()?;
assert_eq!(*widget.area().value().unwrap(), 25);
assert_eq!(*widget.scale(3).value().unwrap(), 15);
// widget dropped here → Drop calls hierlib_releaseInstance
```

**Go:**
```go
lib := hierlib.New()
lib.CreateContext()
v, _ := lib.GetValue()   // v == 7

widget, _ := lib.MakeWidget(5)
a, _ := widget.Area()    // a == 25
s, _ := widget.Scale(3)  // s == 15
widget.Close()
```

### What changes for the foreign consumer?

Nothing. The generated wrappers expose the same typed methods, events, and
lifecycle regardless of whether the Nim side uses flat brokers or OOP brokers.
The OOP structure is an *authoring* concern — it organizes the Nim side into
clean interface/implementation separation without affecting the foreign API
surface.

### Library shutdown and sub-instance safety

Library shutdown (`<lib>_shutdown` / destructor / `close()`) sweeps any
still-live sub-instances as a safety net. If a consumer leaks a `Widget`
without calling `close()`, the main class teardown will release it. This
prevents dangling references to the processing thread after the library
context is gone.

---

## Comparison: flat brokers vs OOP brokers

| Aspect | Flat brokers | OOP brokers |
|--------|-------------|-------------|
| Definition | `EventBroker:` / `RequestBroker:` at module level | `BrokerInterface(IFace):` groups related brokers |
| State | Stateless; global or context-keyed | Per-instance `ref object` with fields |
| Provider registration | Manual `setProvider` / `listen` | Auto-wired by `BrokerImplement` on `create()` / `createUnderContext()` |
| Polymorphism | None — one provider per context | Per-ctx broker dispatch; multiple impls of one interface, one per context |
| Lifecycle | Manual `clearProvider` / `dropAllListeners` | `close()` cleans up everything |
| DI / Factory | Manual wiring | Built-in `provideFactory` / `create` |
| FFI | `RequestBroker(API)` / `EventBroker(API)` | `BrokerInterface(API, IFace):` — same ABI output |
| When to use | Simple, stateless services; leaf modules | Components with state, multiple implementations, or hierarchical structure |

Both styles produce the same underlying broker machinery at runtime. The OOP
layer is sugar + structure — a method call is a `<Broker>.request(...)` round
trip (provider lookup keyed by ctx, then the provider closure), not a virtual
vtable call. On the multi-thread / `(API)` lane this is what makes cross-thread
tunneling and provider mocking work for direct method calls; on the same thread
it is a thread-local lookup plus a closure call.

---

## Memory model notes

| Aspect | `--mm:refc` | `--mm:orc` |
|--------|-------------|------------|
| Instance allocation | `create()` → GC-managed ref | `create()` → GC-managed ref |
| Closure cycle | `instance -> provider closure -> instance` — **must** call `close()` to break | Cycle collector handles it, but `close()` is still recommended for deterministic cleanup |
| `close()` | Mandatory to avoid leaks | Recommended for prompt resource release |
| `createUnderContext` | Same ownership rules | Same ownership rules |
| cross-thread method call | caller borrows `self` (no incref), reads value `brokerCtx`, tunnels via channel | shared heap + atomic RC; tunnels via channel |

---

## Files

| File | Role |
|------|------|
| `brokers/broker_interface.nim` | `BrokerInterface` macro — generates the base type, event facade, public tunneling request procs, factory |
| `brokers/broker_implement.nim` | `BrokerImplement` macro — re-emits the user `proc new`, generates `create()` / `createUnderContext()`, the optional `init(self)` hook, provider wiring, `close()` |
| `test/test_broker_oop.nim` | In-process unit tests: lifecycle, dispatch, events, factory/DI, sub-instances |
| `test/test_broker_interface_api.nim` | FFI API integration tests |
| `test/test_broker_interface_mt.nim` | Multi-thread interface tests |
| `examples/ffiapi/hierlib/` | Full FFI example using the OOP model (C++, Python, Rust, Go consumers) |
