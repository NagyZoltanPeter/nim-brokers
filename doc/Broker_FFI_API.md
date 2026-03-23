# Broker FFI API

## Overview

The Broker FFI API is the shared-library integration layer built on top of
`RequestBroker(API)`, `EventBroker(API)`, and `registerBrokerLibrary`.

It is intended for cases where a Nim component should be consumed from foreign
languages while still using nim-brokers internally for typed request/response
and event delivery.

Typical consumers are:

- plain C applications
- C++ applications through the generated wrapper class
- Python applications through the generated ctypes wrapper

The FFI API solution provides:

- C-callable request functions for API request brokers
- C-callable event registration functions for API event brokers
- a generated library lifecycle API
- a generated C header
- a generated C++ wrapper layer inside that header
- an optional generated Python wrapper module

The FFI API is designed around a per-library-context runtime model. Each call to
`<lib>_create()` creates one independent broker context with its own worker
threads and broker registrations.

---

## Building Blocks

The FFI API layer is composed from three parts.

### 1. `RequestBroker(API)`

Defines a request type that is exported as a C ABI function.

Example:

```nim
RequestBroker(API):
  type GetDevice = object
    deviceId*: int64
    name*: string

  proc signature*(deviceId: int64): Future[Result[GetDevice, string]] {.async.}
```

This generates:

- a C result struct
- a C-exported request function such as `get_device_request_with_args(...)`
- a `free_*_result(...)` function for result-owned memory
- C++ and Python wrapper methods built from the same declaration

### 2. `EventBroker(API)`

Defines an event type that can be subscribed to from foreign code.

Example:

```nim
EventBroker(API):
  type DeviceDiscovered = object
    deviceId*: int64
    name*: string
```

This generates:

- a C callback typedef
- `on<EventType>(ctx, callback)`
- `off<EventType>(ctx, handle)`
- generated wrapper registration methods in C++ and Python

### 3. `registerBrokerLibrary`

This macro ties the API request and event brokers into a complete shared
library surface.

Example:

```nim
registerBrokerLibrary:
  name: "mylib"
  createRequest: CreateRequest
  destroyRequest: DestroyRequest
```

This generates:

- `mylib_initialize()`
- `mylib_create()`
- `mylib_shutdown(ctx)`
- `mylib_free_string(...)`
- the library context registry
- the delivery and processing threads
- aggregate event registration routing
- generated header and optional Python wrapper output

---

## Lifecycle Model

The FFI API deliberately separates process initialization from per-context
creation.

### Process-wide runtime setup

`<lib>_initialize()` must be called once before using the library from foreign
code.

Responsibilities:

- initialize the Nim runtime
- configure foreign-thread GC support where applicable
- set the Nim GC stack bottom for the caller thread

This is a process-wide operation. It does not create broker contexts and it does
not register request providers.

### Per-context creation

`<lib>_create()` creates one independent library instance.

Responsibilities:

- allocate a fresh `BrokerContext`
- start the delivery thread
- start the processing thread
- wait until both threads report readiness
- publish the context in the library registry

The startup handshake is synchronous from the caller point of view. When
`<lib>_create()` returns non-zero, the delivery side and processing side are
already ready for use.

This is why the examples do not need a post-create sleep.

Sequence overview:

```mermaid
sequenceDiagram
  actor F as Foreign caller
  participant I as mylib_initialize()
  participant C as mylib_create()
  participant D as Delivery thread
  participant P as Processing thread
  participant R as Context registry
  F->>I: initialize once per process
  I-->>F: Nim runtime ready
  F->>+C: create context
  C->>C: allocate BrokerContext
  C-)D: start delivery thread
  D->>D: install event registration provider
  D-->>C: deliveryReady = true
  C-)P: start processing thread
  P->>P: run setupProviders(ctx)
  P-->>C: processingReady = true
  C->>R: publish active context
  C-->>-F: return ctx
  Note over F,C: create() blocks until both worker threads are ready
```

### Post-create configuration

`CreateRequest` is the request broker type used for configuration after the
context exists.

Typical responsibilities:

- load configuration files
- initialize thread-local provider state
- register additional providers lazily
- validate environment or external dependencies

### Shutdown

`DestroyRequest` is the broker request type for orderly application-level
teardown.

`<lib>_shutdown(ctx)` stops the delivery and processing threads and marks the
context inactive in the registry.

Recommended order:

1. call `DestroyRequest`
2. unregister or drop external listeners if needed
3. call `<lib>_shutdown(ctx)`

---

## Threading Architecture

Each created library context owns two threads.

### Processing thread

Purpose:

- hosts API request providers
- runs `setupProviders(ctx)` during startup
- serves requests for `RequestBroker(API)` types

This is the thread on which provider closures execute.

### Delivery thread

Purpose:

- hosts the generated event-listener registration broker
- accepts `on<Event>` / `off<Event>` calls from foreign code
- executes foreign callback trampolines for API event delivery

This is the thread that invokes C callbacks and the callback trampolines used by
the generated C++ and Python wrappers.

### Why there are two threads

The split avoids mixing foreign callback delivery with request provider logic.

Benefits:

- event callback dispatch is isolated from request execution
- request providers can keep request-local state on the processing thread
- event registration is always owned by the delivery thread
- shutdown ordering is predictable

### Startup ordering

The generated create function starts the threads in this order:

1. delivery thread
2. processing thread

The delivery thread is started first so event registration requests are routable
before the context is returned to the caller.

The create function waits for:

- delivery thread readiness after the event registration provider is installed
- processing thread readiness after `setupProviders(ctx)` completes

The sequence above is the reason `create()` behaves synchronously even though
the implementation starts two background threads internally.

### Event behavior

When foreign code registers an event callback:

- the registration call goes through the generated `RegisterEventListenerResult`
  request broker
- that request is served on the delivery thread
- the delivery thread stores the listener handle and callback wrapper

When the Nim side emits an API event:

- the event is routed by the generated multi-thread event broker
- same-thread delivery uses direct async dispatch
- cross-thread delivery uses async channels
- foreign callbacks run on the delivery thread

```mermaid
sequenceDiagram
  participant P as Processing thread
  participant E as API EventBroker(mt)
  participant D as Delivery thread
  participant T as FFI callback trampoline
  actor F as Foreign callback
  P->>E: emit(event)
  alt listener already owned by processing thread
    E-)P: dispatch directly
  else listener owned by delivery thread
    E-)D: route event over AsyncChannel
    D->>T: decode payload and invoke wrapper
    T->>F: callback(payload)
  end
  Note over D,F: Foreign callbacks execute on the delivery thread
  Note over D,F: Blocking callback code stalls later callback delivery
```

### Request behavior

API request brokers use the same multi-thread request broker runtime as
`RequestBroker(mt)`.

That means:

- same-thread requests call the provider directly
- cross-thread requests are routed through an `AsyncChannel`
- the provider thread owns the provider closure
- one provider exists per broker type per broker context

```mermaid
sequenceDiagram
  actor F as Foreign caller
  participant X as generated *_request* export
  participant B as RequestBroker(mt)
  participant P as Processing thread
  participant H as provider closure
  F->>+X: blocking C / C++ / Python request call
  X->>+B: request(ctx, args)
  alt caller already on processing thread
    B->>+H: invoke provider directly
    H-->>B: Result[T, string]
    deactivate H
  else caller on foreign thread
    B-)P: enqueue request on AsyncChannel
    P->>+H: invoke provider on processing thread
    H-->>P: Result[T, string]
    deactivate H
    P-->>B: completed result
  end
  B-->>X: marshalled C result
  deactivate B
  X-->>F: return to caller
  deactivate X
  Note over F,X: Foreign request call blocks until the provider finishes
  Note over P,H: Provider code always runs on the processing thread
```

See [Multi-Thread RequestBroker](MultiThread_RequestBroker.md) for the lower
level request-routing behavior that the FFI API builds on.

---

## Requirements on `CreateRequest` and `DestroyRequest`

`registerBrokerLibrary` requires that the types named in `createRequest:` and
`destroyRequest:` exist at compile time.

It does not itself force those providers to be registered.

In practice:

- `CreateRequest.setProvider(ctx, ...)` should be installed in `setupProviders`
  if you want the generated `create_request_*` export to be immediately usable
- `DestroyRequest.setProvider(ctx, ...)` should also usually be installed there
  if you want a stable always-available lifecycle API

For other API request brokers, lazy registration is allowed.

For example, a library may:

- register `CreateRequest` and `DestroyRequest` during startup
- use `CreateRequest.request(...)` to install additional API broker providers

This works because `CreateRequest` executes on the processing thread, which is
the correct owner thread for `setProvider` on API request brokers.

The main limitation is that a provider can only be registered once per broker
type per context unless it is cleared first.

---

## Authoring a Broker FFI Library

### Minimal structure

```nim
import brokers/[event_broker, request_broker, broker_context]
when defined(BrokerFfiApi):
  import brokers/api_library

RequestBroker(API):
  type CreateRequest = object
    initialized*: bool

  proc signature*(configPath: string): Future[Result[CreateRequest, string]] {.async.}

RequestBroker(API):
  type DestroyRequest = object
    status*: int32

  proc signature*(): Future[Result[DestroyRequest, string]] {.async.}

EventBroker(API):
  type StatusChanged = object
    label*: string

var gProviderCtx {.threadvar.}: BrokerContext

proc setupProviders(ctx: BrokerContext) =
  gProviderCtx = ctx

  discard CreateRequest.setProvider(
    ctx,
    proc(configPath: string): Future[Result[CreateRequest, string]] {.closure, async.} =
      return ok(CreateRequest(initialized: true))
  )

  discard DestroyRequest.setProvider(
    ctx,
    proc(): Future[Result[DestroyRequest, string]] {.closure, async.} =
      return ok(DestroyRequest(status: 0))
  )

when defined(BrokerFfiApi):
  registerBrokerLibrary:
    name: "mylib"
    createRequest: CreateRequest
    destroyRequest: DestroyRequest
```

### `setupProviders(ctx)` convention

If a proc named `setupProviders(ctx: BrokerContext)` exists, the generated
library startup calls it automatically on the processing thread.

That proc is the main hook for:

- registering request providers
- capturing thread-local state
- remembering the active provider context
- installing lazily created providers if desired

### Data ownership for request results

The generated C request exports return C structs that may own allocated strings
or arrays.

Foreign code must free them using the generated `free_*_result(...)` function.

The generated C++ and Python wrappers hide that cleanup automatically.

---

## Generated Foreign Surfaces

### C API

The generated C surface contains:

- lifecycle functions
- one exported request function per API request broker signature
- one free function per request result type
- event callback typedefs and `on/off` registration functions

Example:

```c
void mylib_initialize(void);
uint32_t mylib_create(void);
void mylib_shutdown(uint32_t ctx);

CreateRequestCResult create_request_request_with_args(uint32_t ctx, const char* configPath);
void free_create_request_result(CreateRequestCResult* r);

uint64_t onDeviceDiscovered(uint32_t ctx, DeviceDiscoveredCCallback callback);
void offDeviceDiscovered(uint32_t ctx, uint64_t handle);
```

### C++ wrapper

The generated header also contains a wrapper class.

Current lifecycle shape:

- `Mylib::initialize()` for process-wide runtime init
- `lib.create()` for per-context creation
- `lib.shutdown()` for shutdown
- request wrapper methods such as `createRequest(...)`, `listDevices()`, and
  `getDevice(...)`

Example:

```cpp
Mylib::initialize();
Mylib lib;
if (!lib.create()) {
    return 1;
}

auto res = lib.createRequest("/opt/devices.yaml");
if (!res.ok()) {
    std::fprintf(stderr, "%s\n", res.error().c_str());
}
```

### Python wrapper

When Python generation is enabled, a ctypes wrapper module is emitted.

The Python wrapper differs slightly from C and C++:

- `Mylib()` automatically loads the library
- the constructor calls `mylib_initialize()`
- the constructor also calls `mylib_create()`
- `shutdown()` is exposed for explicit teardown

Example:

```python
from mylib import Mylib

with Mylib() as lib:
    res = lib.create_request("/opt/devices.yaml")
    print(res.config_path)
```

---

## Build Requirements

### Required compiler flags

The FFI API needs:

- `-d:BrokerFfiApi`
- `--threads:on`
- `--app:lib`
- `--nimMainPrefix:<libname>`

The example build also uses an explicit output directory.

Example:

```sh
nim c \
  -d:BrokerFfiApi \
  --threads:on \
  --app:lib \
  --nimMainPrefix:mylib \
  --path:src \
  --outdir:examples/ffiapi/nimlib/build \
  examples/ffiapi/nimlib/mylib.nim
```

Optional:

- `-d:BrokerFfiApiGenPy` to generate the Python wrapper

### Memory manager

Use one of:

- `--mm:orc`
- `--mm:refc`

The repository examples and tests support both.

### Why `--nimMainPrefix` matters

The generated `registerBrokerLibrary` code imports `<libname>NimMain`.

That symbol is produced by compiling with the matching Nim main prefix. If the
prefix does not match the library name used in `registerBrokerLibrary`, the
library will fail to link.

### Example tasks in this repository

The repository provides convenience tasks:

- `nimble buildFfiExample`
- `nimble buildFfiExamplePy`
- `nimble buildFfiExampleC`
- `nimble buildFfiExampleCpp`
- `nimble runFfiExampleC`
- `nimble runFfiExampleCpp`
- `nimble runFfiExamplePy`
- `nimble testApi`

---

## Operational Expectations

### What `mylib_create()` guarantees

When `mylib_create()` succeeds:

- the event registration provider is already installed
- the processing thread already ran `setupProviders(ctx)`
- API requests and event listener registration can be used immediately

### What it does not guarantee

It does not guarantee that every API broker has a provider unless your
`setupProviders(ctx)` registered them.

If a generated request export is called before its broker has a provider, it
returns a normal broker error result rather than crashing.

### Callback behavior

Foreign event callbacks should be treated as non-blocking callback code.

Recommended practice:

- do lightweight work in the callback
- hand off expensive processing to your own queue or thread
- avoid blocking the delivery thread for long periods

### Provider behavior

Request providers run on the processing thread and may be async. That means:

- multiple requests can be interleaved across await points
- provider code should protect mutable shared state if reentrancy matters
- shutting down external resources should account for in-flight work

---

## Related Documents

- [Multi-Thread RequestBroker](MultiThread_RequestBroker.md)
- [Multi-Thread EventBroker](MultiThread_EventBroker.md)
