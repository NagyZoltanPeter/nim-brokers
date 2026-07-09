# nim-brokers

**Define the interface once. Get decoupled in-proc calls, cross-thread messaging, and multi-language FFI**

Every non-trivial Nim project eventually hand-rolls dynamic dispatch across a
module, thread, or DLL boundary — vtables, callback tables, channel wiring, FFI
trampolines — and does it a little differently each time. `nim-brokers` replaces
that with **one declared, compile-time-checked fully typed interface** and generates the plumbing: 
  - in-process it's a direct call,
  - across threads it's a lock-free ring,
  - across a language boundary it's a generated type-safe / C++ / Python / Rust / Go wrapper - over extensible CBOR tunneling.

**Same declaration. You choose the reach by adding a tag, not by rewriting — and pay only for the axis you compile in.**

Built on [chronos](https://github.com/status-im/nim-chronos) and [results](https://github.com/arnetheduck/nim-results).

#### Deep dive here:

&nbsp;·&nbsp; [![DeepWiki](https://img.shields.io/badge/DeepWiki-NagyZoltanPeter%2Fnim--brokers-blue.svg)](https://deepwiki.com/NagyZoltanPeter/nim-brokers)
&nbsp;·&nbsp; **[Broker Presentation slides](https://nagyzoltanpeter.github.io/nim-brokers/BrokerDesignPrezi.html)**
&nbsp;·&nbsp; **[Full Usage Guide → USAGEGUIDE.md](USAGEGUIDE.md)**
&nbsp;·&nbsp; **[Cookbook with examples → doc/COOKBOOK.md](doc/COOKBOOK.md)**
> Per-release history in [CHANGELOG.md](CHANGELOG.md).

## The pain it removes

You have a component that other code needs to call, but you don't want a hard
dependency on its implementation — you want to mock it in tests, swap it at
runtime, or move it behind a thread or a shared library later. The usual answer
is a hand-rolled `{.base.}` method vtable plus wiring. `nim-brokers` gives you a
declared contract instead:

```nim
import brokers/broker_interface, brokers/broker_implement

# --- The contract: declared once, compile-time checked ---
BrokerInterface(IGreeter):
  RequestBroker:
    proc greet(name: string): Future[Result[string, string]] {.async.}

# --- An implementation, wired to the contract ---
type GreeterImpl = ref object of IGreeter
  prefix: string

BrokerImplement GreeterImpl of IGreeter:
  proc new(T: typedesc[GreeterImpl], prefix: string): GreeterImpl =
    GreeterImpl(prefix: prefix)
  method greet(self: GreeterImpl, name: string): Future[Result[string, string]] {.async.} =
    ok(self.prefix & name)

let g = GreeterImpl.create(prefix = "hello ")
assert (waitFor g.greet("alice")).value == "hello alice"

# Calls tunnel through the broker, so a test swaps the provider — no DI framework:
Greet.withMockProvider(g.brokerCtx,
  proc(name: string): Future[Result[string, string]] {.async.} = ok("MOCK<" & name & ">")):
  assert (waitFor g.greet("alice")).value == "MOCK<alice>"
```

No `{.base.}` methods, no manual vtable, no service locator. The consumer depends
on `IGreeter`; the implementation is registered at runtime and swappable per
instance.

> **Note:** Every broker can be use as per-broker interface, untied from the BrokerInterface / BrokerImplement pattern. 

## Pay only for the axis you compile in

The same broker declaration reaches as far as you compile it — you don't rewrite
the interface to cross a boundary, you tag it:

| Axis | Tag | What you get |
|------|-----|--------------|
| **Single-thread** | *(none)* | Zero-cost direct dispatch on one chronos loop. |
| **Cross-thread** | `(mt)` | Lock-free MPSC ring + slab, one shared signal per thread. Same call shape. |
| **Cross-language** | `(API)` | A shared library with a fixed CBOR ABI and generated **C / C++ / Python / Rust / Go** wrappers. |

```nim
RequestBroker:         type Weather = object  # single-thread async/sync execution.
RequestBroker(mt):     type Weather = object  # now cross-thread — same call sites
RequestBroker(API):    type Weather = object  # cross-thread + now a multi-language shared library
```

Author the API once in Nim; the generator emits `libmylib`, the header, and
idiomatic wrappers — foreign callers get typed `Result`/error surfaces, owner-aware
event callbacks, and both synchronous (`_call`) and non-blocking (`_callAsync`)
requests, with no hand-written FFI plumbing.

## The brokers

| Broker | Shape | One-liner |
|--------|-------|-----------|
| **EventBroker** | pub/sub, many→many | fire-and-forget events; `listen` / `emit`. |
| **RequestBroker** | request/response, 1 provider, many→one | typed `request()` to a swappable provider; async **or** sync. |
| **MultiRequestBroker** | request/response, N providers, many→many | fan out to all providers, aggregate results. |
| **SignalBroker** | one-way, 1 handler, many→one | fire-and-forget signal with accept/backpressure result. |

```nim
# EventBroker — reactive pub/sub
EventBroker:
  type GreetingEvent = object
    text*: string
discard GreetingEvent.listen(proc(e: GreetingEvent): Future[void] {.async: (raises: []).} = echo e.text)
GreetingEvent.emit(text = "hello")     # sync, fire-and-forget
```

```nim
# RequestBroker — single-provider request/response (sync mode shown)
RequestBroker(sync):
  proc PlusOp*(a: int, b: int): Result[int, string]
PlusOp.setProvider(proc(a, b: int): Result[int, string] = ok(a + b))
echo PlusOp.request(2, 3).get()        # 5
```

Every broker has single-thread, `(mt)`, and `(API)` variants (except
MultiRequestBroker), can be scoped to a `BrokerContext` for isolation, and keeps
the **same call shape across all lanes** — `emit` is always sync, `drop*` is
always async. Full syntax, all variants, and worked examples are in the
**[Usage Guide](USAGEGUIDE.md#types-of-brokers)**.

## Use it for

- **Decoupling modules / plugin boundaries** — a compile-time-checked contract
  instead of a hand-rolled vtable, with runtime-swappable implementations.
- **Dependency Injection / IoC** — providers registered and replaced at runtime;
  `withMockProvider` makes components trivially mockable in isolation.
- **Proactive/Reactive patterns** — easily implement reactive streams and event-driven architectures.
- **Cross-thread messaging** — move a provider or listener onto a dedicated
  thread without writing channel plumbing; the interface doesn't change.
- **Shipping a Nim library to other languages** — one Nim source becomes a
  shared library with typed, memory-safe C / C++ / Python / Rust / Go wrappers
  and no manual binding code.

## Documentation

- **[USAGEGUIDE.md](USAGEGUIDE.md)** — full reference: every broker variant,
  the OOP/DI layer, multi-thread tuning, the FFI API, and memory footprints.
- [Broker FFI API](doc/FFI_API.md) · [Type-support matrix](doc/TYPESUPPORT.md) ·
  [OOP Brokers](doc/OOP_Brokers.md) · [MT config & tuning](doc/MT_BROKER_CONFIG.md) · [Cookbook with examples](doc/COOKBOOK.md)
- [AI Coding agent skill](doc/CLAUDE_brokers_addon.md) <= Add this to your AGENTS/CLAUDE.md


## Platform & Nim version support

Every supported platform × Nim version × memory manager combination is CI-green
on every PR. Build floor: **Nim ≥ 2.2.0**. Recommended baseline: **Nim ≥ 2.2.10
with `--mm:orc`**; **Nim ≥ 2.2.4 + refc** is also fully supported on every
platform. See [USAGEGUIDE.md](USAGEGUIDE.md#platform--nim-version-support) and
[LIMITATION.md](doc/LIMITATION.md) for the Windows-refc caveat and toolchain notes.

## License

MIT

## Credits

`nim-brokers` builds on [**chronos**](https://github.com/status-im/nim-chronos)
(async runtime, `Future[T]`, `ThreadSignalPtr`) and
[**jsoncons**](https://github.com/danielaparker/jsoncons) (header-only C++
JSON/CBOR library used by the generated CBOR-mode C++ wrappers, vendored under
`vendor/jsoncons`). Many thanks to the maintainers and contributors of both projects.
