# nim-brokers

Type-safe, thread-local, decoupled messaging patterns for Nim, built on top of [chronos](https://github.com/status-im/nim-chronos) and [results](https://github.com/status-im/nim-results).

nim-brokers provides three compile-time macro-generated broker patterns that enable event-driven and request-response communication between modules without direct dependencies.

## Installation

```
nimble install brokers
```

Or add to your `.nimble` file:

```nim
requires "brokers >= 0.1.0"
```

## Broker Types

### EventBroker

Reactive pub/sub: many emitters → many listeners. Listeners are async procs; events are dispatched via `asyncSpawn` (fire-and-forget).

```nim
import brokers/event_broker

EventBroker:
  type GreetingEvent = object
    text*: string

# Register a listener (returns a handle for later removal)
let handle = GreetingEvent.listen(
  proc(evt: GreetingEvent): Future[void] {.async: (raises: []).} =
    echo evt.text
)

# Emit by value
GreetingEvent.emit(GreetingEvent(text: "hello"))

# Emit by fields (inline object types only)
GreetingEvent.emit(text = "hello")

# Remove a single listener
GreetingEvent.dropListener(handle.get())

# Remove all listeners
GreetingEvent.dropAllListeners()
```

### RequestBroker

Single-provider request/response. One provider registers; callers make typed requests. Supports both **async** (default) and **sync** modes.

```nim
import brokers/request_broker

# Async mode (default)
RequestBroker:
  type Greeting = object
    text*: string

  proc signature*(): Future[Result[Greeting, string]] {.async.}
  proc signature*(lang: string): Future[Result[Greeting, string]] {.async.}

Greeting.setProvider(
  proc(): Future[Result[Greeting, string]] {.async.} =
    ok(Greeting(text: "hello"))
)

let res = await Greeting.request()
assert res.isOk()
Greeting.clearProvider()
```

```nim
# Sync mode
RequestBroker(sync):
  type Config = object
    value*: string

  proc signature*(): Result[Config, string]

Config.setProvider(
  proc(): Result[Config, string] =
    ok(Config(value: "default"))
)

let res = Config.request()  # no await needed
Config.clearProvider()
```

If no `signature` proc is declared, a zero-argument form is generated automatically.

### MultiRequestBroker

Multi-provider fan-out request/response (async only). Multiple providers register; `request()` calls all of them and aggregates the results. The request fails if any provider fails.

```nim
import brokers/multi_request_broker

MultiRequestBroker:
  type Info = object
    label*: string

  proc signature*(): Future[Result[Info, string]] {.async.}

discard Info.setProvider(
  proc(): Future[Result[Info, string]] {.async.} =
    ok(Info(label: "from-module-a"))
)

discard Info.setProvider(
  proc(): Future[Result[Info, string]] {.async.} =
    ok(Info(label: "from-module-b"))
)

let responses = await Info.request()  # Result[seq[Info], string]
assert responses.get().len == 2

# Remove a specific provider by handle
let handle = Info.setProvider(myHandler)
Info.removeProvider(handle.get())

# Remove all providers
Info.clearProviders()
```

## BrokerContext

All three brokers support scoped instances via `BrokerContext`. This is useful when multiple independent components on the same thread each need their own broker state (e.g. separate listener/provider sets).

```nim
import brokers/broker_context
import brokers/event_broker

EventBroker:
  type MyEvent = object
    value*: int

let ctxA = NewBrokerContext()
let ctxB = NewBrokerContext()

# Listeners registered under different contexts are isolated
discard MyEvent.listen(ctxA, proc(evt: MyEvent): Future[void] {.async: (raises: []).} =
  echo "A: ", evt.value
)
discard MyEvent.listen(ctxB, proc(evt: MyEvent): Future[void] {.async: (raises: []).} =
  echo "B: ", evt.value
)

MyEvent.emit(ctxA, MyEvent(value: 1))  # only context A listener fires
MyEvent.emit(ctxB, MyEvent(value: 2))  # only context B listener fires

MyEvent.dropAllListeners(ctxA)
MyEvent.dropAllListeners(ctxB)
```

When no `BrokerContext` argument is passed, the `DefaultBrokerContext` is used.

A global context lock is available via `lockGlobalBrokerContext` for serialized cross-module coordination within `chronos` async procs.

## Non-Object Types

All three brokers support native types, aliases, and externally-defined types. These are automatically wrapped in `distinct` to prevent overload ambiguity. If the type is already `distinct`, it is preserved as-is.

```nim
RequestBroker(sync):
  type Counter = int  # exported as `distinct int`

Counter.setProvider(proc(): Result[Counter, string] = ok(Counter(42)))
let val = int(Counter.request().get())  # unwrap with cast
```

## Testing

```
nimble test
```

## Debug

To inspect generated AST during compilation:

```
nim c -d:brokerDebug ...
```

## Prezentation slides  

[available here](https://nagyzoltanpeter.github.io/nim-brokers/BrokerDesignPrezi.html).

## License

MIT
